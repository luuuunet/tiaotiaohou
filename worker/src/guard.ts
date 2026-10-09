export function isCloudflareIp(host: string): boolean {
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!match) return false;
  const octets = match.slice(1).map((part) => Number(part));
  if (octets.some((n) => n > 255)) return false;
  const ip = ((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) >>> 0;
  const nets: Array<[number, number]> = [
    [ip4(173, 245, 48, 0), 20],
    [ip4(103, 21, 244, 0), 22],
    [ip4(103, 22, 200, 0), 22],
    [ip4(103, 31, 4, 0), 22],
    [ip4(141, 101, 64, 0), 18],
    [ip4(108, 162, 192, 0), 18],
    [ip4(190, 93, 240, 0), 20],
    [ip4(188, 114, 96, 0), 20],
    [ip4(197, 234, 240, 0), 22],
    [ip4(198, 41, 128, 0), 17],
    [ip4(162, 158, 0, 0), 15],
    [ip4(104, 16, 0, 0), 13],
    [ip4(104, 24, 0, 0), 14],
    [ip4(172, 64, 0, 0), 13],
    [ip4(131, 0, 72, 0), 22],
    [ip4(1, 1, 1, 0), 24],
    [ip4(1, 0, 0, 0), 24],
  ];
  return nets.some(([base, bits]) => {
    const mask = (0xffffffff << (32 - bits)) >>> 0;
    return (ip & mask) === (base & mask);
  });
}

function ip4(a: number, b: number, c: number, d: number): number {
  return ((a << 24) | (b << 16) | (c << 8) | d) >>> 0;
}

export function blockReason(host: string, port: number): string | null {
  if (!Number.isInteger(port) || port <= 0 || port > 65535 || port === 25) {
    return "这个端口不能转发";
  }
  if (!host || host.length > 253) return "主机名不合法";
  if (/[\u0000-\u001f\/\\ @#?]/.test(host)) return "主机名不合法";
  const lower = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (
    lower === "localhost" ||
    lower.endsWith(".localhost") ||
    lower.endsWith(".local") ||
    lower === "metadata.google.internal"
  ) {
    return "内网地址不能转发";
  }
  if (isBlockedIp(lower)) return "内网地址不能转发";
  return null;
}

function isBlockedIp(host: string): boolean {
  if (host.includes(":")) {
    const v6 = host.split("%")[0];
    if (v6 === "::1" || v6 === "::") return true;
    const head = v6.split(":")[0] || "0";
    const n = parseInt(head, 16);
    if (Number.isNaN(n)) return false;
    if ((n & 0xfe00) === 0xfc00) return true;
    if ((n & 0xffc0) === 0xfe80) return true;
    if ((n & 0xff00) === 0xff00) return true;
    return false;
  }
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const o = m.slice(1).map((x) => Number(x));
  if (o.some((n) => n > 255)) return true;
  const [a, b, c] = o;
  if (a === 0 || a === 10 || a === 127) return true;
  if (a === 100 && (b & 0xc0) === 64) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 192 && b === 0 && c === 2) return true;
  if (a === 198 && (b === 18 || b === 19)) return true;
  if (a === 198 && b === 51 && c === 100) return true;
  if (a === 203 && b === 0 && c === 113) return true;
  if (a >= 224) return true;
  return false;
}

export async function tokenOk(presented: string, expected: string): Promise<boolean> {
  if (!expected) return false;
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(presented)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const aa = new Uint8Array(a);
  const bb = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i];
  return diff === 0;
}
