#!/usr/bin/env python3
"""跳跳猴落地：8443 给 Cloudflare Worker 明文 TCP，8444 给客户端 TLS，UDP 给游戏。"""

from __future__ import annotations

import asyncio
import ipaddress
import os
import socket
import ssl
from pathlib import Path

PORT = int(os.environ.get("TTM_PORT", "8443"))
TLS_PORT = int(os.environ.get("TTM_TLS_PORT", "8444"))
TOKEN_FILE = Path(os.environ.get("TTM_TOKEN_FILE", "/etc/tiaotiaohou/token"))
CERT_FILE = Path(os.environ.get("TTM_CERT_FILE", "/etc/tiaotiaohou/cert.pem"))
KEY_FILE = Path(os.environ.get("TTM_KEY_FILE", "/etc/tiaotiaohou/key.pem"))


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


def tls_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(CERT_FILE), str(KEY_FILE))
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


async def main() -> None:
    if not TOKEN_FILE.exists():
        raise SystemExit(f"缺少令牌文件 {TOKEN_FILE}")
    loop = asyncio.get_running_loop()
    raw = await asyncio.start_server(handle, "0.0.0.0", PORT)
    print(f"tiaotiaohou landing tcp 0.0.0.0:{PORT}", flush=True)
    if CERT_FILE.exists() and KEY_FILE.exists():
        tls = await asyncio.start_server(handle, "0.0.0.0", TLS_PORT, ssl=tls_context())
        print(f"tiaotiaohou landing tls 0.0.0.0:{TLS_PORT}", flush=True)
    else:
        tls = None
        print("tiaotiaohou landing tls skipped (no cert)", flush=True)
    udp_transport, _ = await loop.create_datagram_endpoint(UdpHub, local_addr=("0.0.0.0", TLS_PORT))
    print(f"tiaotiaohou landing udp 0.0.0.0:{TLS_PORT}", flush=True)
    try:
        await asyncio.Future()
    finally:
        raw.close()
        if tls is not None:
            tls.close()
        udp_transport.close()


if __name__ == "__main__":
    asyncio.run(main())
