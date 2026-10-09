import { connect } from "cloudflare:sockets";
import { blockReason, isCloudflareIp, tokenOk } from "./guard";

export interface Env {
  RSQ_TOKEN: string;
  LANDING_HOST?: string;
  LANDING_PORT?: string;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/rsq/v1/health")) {
      if (url.pathname === "/") return text("rsq/1", 200);
      if (!(await authorized(request, env))) return text("unauthorized", 401);
      return Response.json(
        { ok: true, version: 1, proto: "rsq" },
        { headers: { "cache-control": "no-store" } },
      );
    }

    if (url.pathname === "/rsq/v1/fetch" && request.method === "POST") {
      if (!(await authorized(request, env))) return text("unauthorized", 401);
      return fetchSite(request);
    }

    if (url.pathname !== "/rsq/v1/ws" || (request.headers.get("Upgrade") ?? "").toLowerCase() !== "websocket") {
      return text("not found", 404);
    }
    if (!(await authorized(request, env))) return text("unauthorized", 401);

    const host = (request.headers.get("x-rsq-host") ?? "").trim();
    const port = Number(request.headers.get("x-rsq-port"));
    const denied = blockReason(host, port);
    if (denied) return text(denied, 403);

    let socket: ReturnType<typeof connect>;
    let prefix = new Uint8Array();
    try {
      const via = (request.headers.get("x-rsq-exit") ?? "landing").trim();
      const opened = await openExit(env, host, port, via);
      socket = opened.socket;
      prefix = opened.prefix;
    } catch (err) {
      return text(`connect failed: ${err instanceof Error ? err.message : String(err)}`, 502);
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    server.binaryType = "arraybuffer";
    ctx.waitUntil(bind(server, socket, prefix));
    return new Response(null, { status: 101, webSocket: client });
  },
};

async function openExit(
  env: Env,
  host: string,
  port: number,
  via: string,
): Promise<{ socket: ReturnType<typeof connect>; prefix: Uint8Array }> {
  const landingHost = (env.LANDING_HOST ?? "").trim();
  const landingPort = Number(env.LANDING_PORT || "0");
  if (via === "direct" || !landingHost || !landingPort) {
    const socket = connect({ hostname: host, port });
    await socket.opened;
    return { socket, prefix: new Uint8Array() };
  }
  const socket = connect({ hostname: landingHost, port: landingPort });
  await socket.opened;
  const token = new TextEncoder().encode(env.RSQ_TOKEN ?? "");
  const hostBytes = new TextEncoder().encode(host);
  const head = new Uint8Array(1 + 2 + token.byteLength + 2 + hostBytes.byteLength + 2);
  let offset = 0;
  head[offset++] = 1;
  head[offset++] = token.byteLength >> 8;
  head[offset++] = token.byteLength & 0xff;
  head.set(token, offset);
  offset += token.byteLength;
  head[offset++] = hostBytes.byteLength >> 8;
  head[offset++] = hostBytes.byteLength & 0xff;
  head.set(hostBytes, offset);
  offset += hostBytes.byteLength;
  head[offset++] = port >> 8;
  head[offset++] = port & 0xff;
  const writer = socket.writable.getWriter();
  await writer.write(head);
  writer.releaseLock();
  const reader = socket.readable.getReader();
  const ack = await reader.read();
  reader.releaseLock();
  const raw = ack.value ? new Uint8Array(ack.value) : new Uint8Array();
  if (ack.done || raw.byteLength < 1 || raw[0] !== 1) throw new Error("landing refused");
  return { socket, prefix: raw.subarray(1).slice() };
}

async function bind(server: WebSocket, socket: ReturnType<typeof connect>, prefix: Uint8Array): Promise<void> {
  const writer = socket.writable.getWriter();
  const reader = socket.readable.getReader();
  const writing = new Promise<void>((resolve) => {
    server.addEventListener("message", (event) => {
      const data = event.data;
      const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array();
      if (bytes.byteLength) writer.write(bytes).catch(() => server.close());
    });
    server.addEventListener("close", () => resolve());
    server.addEventListener("error", () => resolve());
  });
  const reading = (async () => {
    try {
      if (prefix.byteLength) server.send(prefix);
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        if (next.value?.byteLength) server.send(next.value);
      }
    } catch {
      // 对端已断开，下面统一关闭。
    }
    server.close();
  })();
  await Promise.race([writing, reading]);
  await writer.close().catch(() => undefined);
  server.close();
}

async function fetchByIp(
  urlString: string,
  method: string,
  headers: Headers,
  body: ArrayBuffer | undefined,
  ip: string,
): Promise<Response> {
  const target = new URL(urlString);
  const https = target.protocol === "https:";
  const port = Number(target.port || (https ? 443 : 80));
  let socket = connect({ hostname: ip, port });
  await socket.opened;
  if (https) socket = socket.startTls({ expectedServerHostname: target.hostname });
  const writer = socket.writable.getWriter();
  const lines = [`${method} ${target.pathname}${target.search} HTTP/1.1`, `Host: ${target.host}`, "Connection: close"];
  headers.forEach((value, key) => lines.push(`${key}: ${value}`));
  const payload = body ? new Uint8Array(body) : new Uint8Array();
  if (payload.byteLength) lines.push(`Content-Length: ${payload.byteLength}`);
  await writer.write(new TextEncoder().encode(`${lines.join("\r\n")}\r\n\r\n`));
  if (payload.byteLength) await writer.write(payload);
  await writer.close();
  const reader = socket.readable.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (total < 8 * 1024 * 1024) {
    const next = await reader.read();
    if (next.done) break;
    if (next.value?.byteLength) {
      chunks.push(next.value);
      total += next.value.byteLength;
    }
  }
  const raw = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    raw.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const headEnd = findHeaderEnd(raw);
  if (headEnd < 0) return text("bad origin response", 502);
  const head = new TextDecoder().decode(raw.subarray(0, headEnd));
  const [statusLine, ...headerLines] = head.split("\r\n");
  const status = Number(statusLine.split(" ")[1] || "502");
  const out = new Headers();
  let chunked = false;
  let length = -1;
  for (const line of headerLines) {
    const cut = line.indexOf(":");
    if (cut <= 0) continue;
    const name = line.slice(0, cut).trim();
    const value = line.slice(cut + 1).trim();
    if (/^transfer-encoding$/i.test(name) && value.toLowerCase().includes("chunked")) chunked = true;
    if (/^content-length$/i.test(name)) length = Number(value);
    if (/^(connection|transfer-encoding|content-length)$/i.test(name)) continue;
    try {
      out.append(name, value);
    } catch {
      // 跳过不能转发的头。
    }
  }
  let responseBody = raw.subarray(headEnd + 4);
  if (chunked) responseBody = decodeChunks(responseBody);
  else if (length >= 0 && length <= responseBody.length) responseBody = responseBody.subarray(0, length);
  return new Response(responseBody, { status, headers: out });
}

function decodeChunks(raw: Uint8Array): Uint8Array {
  const parts: Uint8Array[] = [];
  let index = 0;
  let total = 0;
  const text = new TextDecoder();
  while (index < raw.length) {
    let lineEnd = index;
    while (lineEnd + 1 < raw.length && !(raw[lineEnd] === 13 && raw[lineEnd + 1] === 10)) lineEnd++;
    const size = parseInt(text.decode(raw.subarray(index, lineEnd)).split(";")[0].trim(), 16);
    if (!Number.isFinite(size) || size <= 0) break;
    index = lineEnd + 2;
    if (index + size > raw.length) break;
    parts.push(raw.subarray(index, index + size));
    total += size;
    index += size + 2;
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    body.set(part, offset);
    offset += part.byteLength;
  }
  return body;
}

function findHeaderEnd(raw: Uint8Array): number {
  for (let i = 0; i + 3 < raw.length; i++) {
    if (raw[i] === 13 && raw[i + 1] === 10 && raw[i + 2] === 13 && raw[i + 3] === 10) return i;
  }
  return -1;
}

async function fetchSite(request: Request): Promise<Response> {
  const buf = await request.arrayBuffer();
  if (buf.byteLength < 4) return text("bad fetch", 400);
  const view = new DataView(buf);
  const metaLen = view.getUint32(0);
  if (metaLen > buf.byteLength - 4) return text("bad fetch", 400);
  const meta = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 4, metaLen))) as {
    method?: string;
    url?: string;
    ip?: string;
    headers?: Record<string, string> | Array<[string, string]>;
  };
  if (!meta.url || !meta.url.startsWith("http")) return text("bad url", 400);
  const headers = new Headers();
  for (const [key, value] of headerPairs(meta.headers)) {
    const name = key.toLowerCase();
    if (["host", "connection", "content-length", "transfer-encoding", "upgrade"].includes(name)) continue;
    try {
      if (name === "cookie") headers.append(key, value);
      else headers.set(key, value);
    } catch {
      // 跳过 Worker 不接受的头。
    }
  }
  const method = (meta.method ?? "GET").toUpperCase();
  const body = buf.byteLength > 4 + metaLen ? buf.slice(4 + metaLen) : undefined;
  if (meta.ip && /^\d{1,3}(?:\.\d{1,3}){3}$/.test(meta.ip) && !isCloudflareIp(meta.ip)) {
    const target = new URL(meta.url);
    const port = Number(target.port || (target.protocol === "https:" ? 443 : 80));
    const denied = blockReason(meta.ip, port);
    if (!denied) {
      try {
        return await fetchByIp(meta.url, method, headers, body, meta.ip);
      } catch {
        // 这个地址连不上时，再交给 fetch。橙云网站会走这里。
      }
    }
  }
  const upstream = await fetch(meta.url, {
    method,
    headers,
    body: body && method !== "GET" && method !== "HEAD" ? body : undefined,
    redirect: "manual",
  });
  return passUpstream(upstream);
}

function headerPairs(raw: Record<string, string> | Array<[string, string]> | undefined): Array<[string, string]> {
  if (Array.isArray(raw)) {
    return raw.flatMap((item) => (Array.isArray(item) && item.length >= 2 ? [[String(item[0]), String(item[1])] as [string, string]] : []));
  }
  return Object.entries(raw ?? {}).map(([key, value]) => [key, String(value)]);
}

function passUpstream(upstream: Response): Response {
  const headers = new Headers();
  upstream.headers.forEach((value, key) => {
    if (key.toLowerCase() === "set-cookie") return;
    try {
      headers.append(key, value);
    } catch {
      // 跳过不能转发的头。
    }
  });
  const listed = upstream.headers.getSetCookie?.() ?? [];
  const cookies = listed.length ? listed : upstream.headers.get("set-cookie") ? [upstream.headers.get("set-cookie") as string] : [];
  for (const cookie of cookies) headers.append("set-cookie", cookie);
  return new Response(upstream.body, { status: upstream.status, headers });
}

async function authorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("authorization") ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  return tokenOk(presented, env.RSQ_TOKEN ?? "");
}

function text(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: { "cache-control": "no-store", "content-type": "text/plain; charset=utf-8" },
  });
}
