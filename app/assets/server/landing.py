#!/usr/bin/env python3
"""跳跳猴落地：8444 明文 TCP 给 Worker，443 HTTPS 给橙云回源，8444 UDP 给游戏。"""

from __future__ import annotations

import asyncio
import ipaddress
import os
import socket
import ssl
from pathlib import Path

import base64
import hashlib
import json

PORT = int(os.environ.get("TTM_PORT", "8444"))
TLS_PORT = int(os.environ.get("TTM_TLS_PORT", "8443"))
ORIGIN_PORT = int(os.environ.get("TTM_ORIGIN_PORT", "443"))
UDP_PORT = int(os.environ.get("TTM_UDP_PORT", "8444"))
TOKEN_FILE = Path(os.environ.get("TTM_TOKEN_FILE", "/etc/tiaotiaohou/token"))
CERT_FILE = Path(os.environ.get("TTM_CERT_FILE", "/etc/tiaotiaohou/cert.pem"))
KEY_FILE = Path(os.environ.get("TTM_KEY_FILE", "/etc/tiaotiaohou/key.pem"))
WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def blocked(host: str, port: int) -> bool:
    if host == "__health__":
        return False
    if port <= 0 or port > 65535 or port == 25:
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


async def read_exact(reader: asyncio.StreamReader, size: int) -> bytes:
    return await reader.readexactly(size)


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def token_ok(got: str) -> bool:
    expected = TOKEN_FILE.read_text(encoding="utf-8").strip()
    return bool(expected) and got == expected


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    remote = None
    try:
        version = (await read_exact(reader, 1))[0]
        if version != 1:
            writer.write(b"\x00")
            await writer.drain()
            return
        token_len = int.from_bytes(await read_exact(reader, 2), "big")
        if token_len <= 0 or token_len > 256:
            writer.write(b"\x00")
            await writer.drain()
            return
        token = (await read_exact(reader, token_len)).decode("utf-8", "replace")
        host_len = int.from_bytes(await read_exact(reader, 2), "big")
        if host_len <= 0 or host_len > 253:
            writer.write(b"\x00")
            await writer.drain()
            return
        host = (await read_exact(reader, host_len)).decode("utf-8", "replace")
        port = int.from_bytes(await read_exact(reader, 2), "big")
        if not token_ok(token) or blocked(host, port):
            writer.write(b"\x00")
            await writer.drain()
            return
        if host == "__health__":
            writer.write(b"\x01")
            await writer.drain()
            return
        remote_reader, remote_writer = await asyncio.open_connection(host, port)
        remote = remote_writer
        writer.write(b"\x01")
        await writer.drain()
        await asyncio.gather(pipe(reader, remote_writer), pipe(remote_reader, writer))
    except Exception:
        if remote is None:
            try:
                writer.write(b"\x00")
                await writer.drain()
            except Exception:
                pass
    finally:
        writer.close()
        if remote is not None:
            remote.close()


def parse_udp(data: bytes) -> tuple[str, str, int, bytes] | None:
    if len(data) < 8 or data[0] != 2:
        return None
    token_len = int.from_bytes(data[1:3], "big")
    if token_len <= 0 or token_len > 256 or len(data) < 3 + token_len + 2:
        return None
    offset = 3
    token = data[offset : offset + token_len].decode("utf-8", "replace")
    offset += token_len
    atyp = data[offset]
    offset += 1
    if atyp == 1:
        if len(data) < offset + 6:
            return None
        host = ".".join(str(b) for b in data[offset : offset + 4])
        offset += 4
    elif atyp == 3:
        n = data[offset]
        offset += 1
        if n <= 0 or len(data) < offset + n + 2:
            return None
        host = data[offset : offset + n].decode("utf-8", "replace")
        offset += n
    else:
        return None
    port = int.from_bytes(data[offset : offset + 2], "big")
    payload = data[offset + 2 :]
    return token, host, port, payload


def pack_udp(host: str, port: int, payload: bytes) -> bytes:
    try:
        ip = ipaddress.ip_address(host)
        if ip.version == 4:
            return b"\x02\x01" + ip.packed + port.to_bytes(2, "big") + payload
    except ValueError:
        pass
    hb = host.encode("utf-8")
    return b"\x02\x03" + bytes([len(hb)]) + hb + port.to_bytes(2, "big") + payload


class UdpHub(asyncio.DatagramProtocol):
    def __init__(self) -> None:
        self.transport: asyncio.DatagramTransport | None = None
        self.nats: dict[tuple[str, int], asyncio.DatagramTransport] = {}
        self.clients: dict[int, tuple[str, int]] = {}

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        parsed = parse_udp(data)
        if parsed is None:
            return
        token, host, port, payload = parsed
        if not token_ok(token) or blocked(host, port):
            return
        asyncio.get_running_loop().create_task(self.forward(addr, host, port, payload))

    async def forward(self, client: tuple[str, int], host: str, port: int, payload: bytes) -> None:
        loop = asyncio.get_running_loop()
        try:
            infos = await loop.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
            dest = infos[0][4]
        except Exception:
            return
        nat = self.nats.get(client)
        if nat is None:
            proto = ClientNat(self, client)
            transport, _ = await loop.create_datagram_endpoint(lambda: proto, local_addr=("0.0.0.0", 0))
            self.nats[client] = transport
            nat = transport
        try:
            nat.sendto(payload, dest)
        except Exception:
            pass


class ClientNat(asyncio.DatagramProtocol):
    def __init__(self, hub: UdpHub, client: tuple[str, int]) -> None:
        self.hub = hub
        self.client = client

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        if self.hub.transport is None:
            return
        host, port = addr[0], addr[1]
        try:
            self.hub.transport.sendto(pack_udp(host, port, data), self.client)
        except Exception:
            pass


def tls_context(*, http: bool = False) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(CERT_FILE), str(KEY_FILE))
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    if http:
        ctx.set_alpn_protocols(["http/1.1"])
    return ctx


def header_map(raw: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in raw:
        cut = line.find(":")
        if cut <= 0:
            continue
        out[line[:cut].strip().lower()] = line[cut + 1 :].strip()
    return out


def authorized(headers: dict[str, str]) -> bool:
    presented = headers.get("authorization", "")
    if presented.lower().startswith("bearer "):
        presented = presented[7:].strip()
    return token_ok(presented)


async def read_headers(reader: asyncio.StreamReader) -> tuple[str, str, dict[str, str], bytes]:
    buf = b""
    while b"\r\n\r\n" not in buf and len(buf) < 65536:
        chunk = await reader.read(4096)
        if not chunk:
            break
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.decode("iso-8859-1", "replace").split("\r\n")
    first = lines[0] if lines else ""
    parts = first.split(" ")
    method = parts[0] if parts else ""
    path = parts[1] if len(parts) > 1 else "/"
    return method, path.split("?", 1)[0], header_map(lines[1:]), rest


async def open_target(host: str, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    if blocked(host, port):
        raise OSError("blocked")
    return await asyncio.open_connection(host, port)


async def handle_tcp_http(req: asyncio.StreamReader, res: asyncio.StreamWriter, host: str, port: int, leftover: bytes) -> None:
    res.write(b"HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\ncache-control: no-store\r\n\r\n")
    await res.drain()
    try:
        remote_r, remote_w = await open_target(host, port)
    except Exception:
        try:
            res.close()
        except Exception:
            pass
        return
    body = leftover
    if not body:
        body = await req.read(1)
    if body[:1] == b"\x00":
        body = body[1:]
    if body:
        remote_w.write(body)
        await remote_w.drain()
    await asyncio.gather(pipe(req, remote_w), pipe(remote_r, res))


def ws_accept(key: str) -> str:
    digest = hashlib.sha1((key + WS_MAGIC).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


async def read_ws_frame(reader: asyncio.StreamReader) -> tuple[int, bytes] | None:
    header = await reader.readexactly(2)
    opcode = header[0] & 0x0F
    masked = header[1] & 0x80
    length = header[1] & 0x7F
    if length == 126:
        length = int.from_bytes(await reader.readexactly(2), "big")
    elif length == 127:
        length = int.from_bytes(await reader.readexactly(8), "big")
    mask = await reader.readexactly(4) if masked else b""
    payload = await reader.readexactly(length)
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def ws_frame(opcode: int, payload: bytes) -> bytes:
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + n.to_bytes(2, "big")
    else:
        header += bytes([127]) + n.to_bytes(8, "big")
    return header + payload


async def handle_ws(req: asyncio.StreamReader, res: asyncio.StreamWriter, host: str, port: int) -> None:
    remote_r, remote_w = await open_target(host, port)

    async def from_client() -> None:
        try:
            while True:
                frame = await read_ws_frame(req)
                if frame is None:
                    break
                opcode, payload = frame
                if opcode in (0, 1, 2) and payload:
                    remote_w.write(payload)
                    await remote_w.drain()
                elif opcode == 8:
                    break
                elif opcode == 9:
                    res.write(ws_frame(0xA, payload))
                    await res.drain()
        except Exception:
            pass
        finally:
            try:
                remote_w.close()
            except Exception:
                pass

    async def from_remote() -> None:
        try:
            while True:
                chunk = await remote_r.read(65536)
                if not chunk:
                    break
                res.write(ws_frame(0x2, chunk))
                await res.drain()
        except Exception:
            pass
        finally:
            try:
                res.close()
            except Exception:
                pass

    await asyncio.gather(from_client(), from_remote())


async def handle_origin(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        method, path, headers, leftover = await read_headers(reader)
        if method == "GET" and path in ("/", "/rsq/v1/health"):
            if path == "/":
                body = b"rsq/1"
                writer.write(b"HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 5\r\ncache-control: no-store\r\n\r\n" + body)
                await writer.drain()
                return
            if not authorized(headers):
                writer.write(b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 12\r\n\r\nunauthorized")
                await writer.drain()
                return
            body = json.dumps({"ok": True, "version": 1, "proto": "rsq"}).encode("utf-8")
            writer.write(
                b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncache-control: no-store\r\ncontent-length: "
                + str(len(body)).encode()
                + b"\r\n\r\n"
                + body
            )
            await writer.drain()
            return
        if not authorized(headers):
            writer.write(b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 12\r\n\r\nunauthorized")
            await writer.drain()
            return
        host = headers.get("x-rsq-host", "").strip()
        port = int(headers.get("x-rsq-port", "0") or "0")
        upgrade = headers.get("upgrade", "").lower()
        if path == "/rsq/v1/ws" and upgrade == "websocket":
            key = headers.get("sec-websocket-key", "")
            if not key or not host or blocked(host, port):
                writer.write(b"HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n")
                await writer.drain()
                return
            accept = ws_accept(key)
            writer.write(
                (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                ).encode("ascii")
            )
            await writer.drain()
            await handle_ws(reader, writer, host, port)
            return
        if method == "POST" and path == "/rsq/v1/tcp":
            if not host or blocked(host, port):
                writer.write(b"HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n")
                await writer.drain()
                return
            await handle_tcp_http(reader, writer, host, port, leftover)
            return
        writer.write(b"HTTP/1.1 404 Not Found\r\ncontent-length: 9\r\n\r\nnot found")
        await writer.drain()
    except Exception:
        try:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n")
            await writer.drain()
        except Exception:
            pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def _listen(label: str, factory):
    try:
        server = await factory()
        print(label, flush=True)
        return server
    except OSError as err:
        print(f"{label} failed: {err}", flush=True)
        return None


async def main() -> None:
    if not TOKEN_FILE.exists():
        raise SystemExit(f"缺少令牌文件 {TOKEN_FILE}")
    loop = asyncio.get_running_loop()
    raw = await _listen(
        f"tiaotiaohou landing tcp 0.0.0.0:{PORT}",
        lambda: asyncio.start_server(handle, "0.0.0.0", PORT),
    )
    tls = None
    origin = None
    if CERT_FILE.exists() and KEY_FILE.exists():
        if TLS_PORT != PORT:
            tls = await _listen(
                f"tiaotiaohou landing tls 0.0.0.0:{TLS_PORT}",
                lambda: asyncio.start_server(handle, "0.0.0.0", TLS_PORT, ssl=tls_context()),
            )
        if ORIGIN_PORT > 0 and ORIGIN_PORT != TLS_PORT:
            origin = await _listen(
                f"tiaotiaohou origin https 0.0.0.0:{ORIGIN_PORT}",
                lambda: asyncio.start_server(handle_origin, "0.0.0.0", ORIGIN_PORT, ssl=tls_context(http=True)),
            )
    else:
        print("tiaotiaohou origin skipped (no cert)", flush=True)
    udp_transport = None
    try:
        udp_transport, _ = await loop.create_datagram_endpoint(UdpHub, local_addr=("0.0.0.0", UDP_PORT))
        print(f"tiaotiaohou landing udp 0.0.0.0:{UDP_PORT}", flush=True)
    except OSError as err:
        print(f"tiaotiaohou landing udp failed: {err}", flush=True)
    if raw is None and origin is None:
        raise SystemExit("没有监听成功")
    try:
        await asyncio.Future()
    finally:
        if raw is not None:
            raw.close()
        if tls is not None:
            tls.close()
        if origin is not None:
            origin.close()
        if udp_transport is not None:
            udp_transport.close()


if __name__ == "__main__":
    asyncio.run(main())
