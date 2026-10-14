export const DEFAULT_PORT = 8080;
export const NATIVE_HOST = 'dev.rsq.tiaotiaohou';

export function normalizePort(value) {
  const port = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  return port;
}

export function bypassList() {
  return [
    'localhost',
    '127.0.0.1',
    '[::1]',
    '<local>',
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '169.254.0.0/16',
    '*.local',
  ];
}

export function proxyConfig(port) {
  return {
    mode: 'fixed_servers',
    rules: {
      singleProxy: {
        scheme: 'http',
        host: '127.0.0.1',
        port,
      },
      bypassList: bypassList(),
    },
  };
}

export function coreReply(status, body) {
  return status === 405 && String(body ?? '').includes('only CONNECT');
}

export function proxyAlreadyApplied(settings, port) {
  const proxy = settings?.value?.rules?.singleProxy;
  return settings?.value?.mode === 'fixed_servers'
    && proxy?.scheme === 'http'
    && proxy?.host === '127.0.0.1'
    && proxy?.port === port;
}

export function browserConfig(input) {
  const port = normalizePort(input?.port);
  if (port == null) return { error: '端口不对，请填 1 到 65535' };
  const endpoint = String(input?.endpoint || '').trim();
  let url;
  try {
    url = new URL(endpoint);
  } catch {
    return { error: '节点地址不合法' };
  }
  if (url.protocol !== 'https:') return { error: '节点必须是 https:// 开头' };
  if (url.username || url.password) return { error: '节点地址不能带用户名' };
  if (url.pathname !== '/' && url.pathname !== '') return { error: '节点地址不要带路径' };
  const token = String(input?.token || '').trim();
  if (!token || token.length > 512 || /[\u0000-\u001f]/.test(token)) return { error: '请填写节点令牌' };
  return {
    endpoint,
    token,
    port,
    config: {
      endpoint,
      token,
      socks_port: port === 1080 ? 1081 : 1080,
      http_port: port,
      prefer_h3: true,
      fetch_enabled: false,
      exit_via: 'landing',
      bypass: [],
      rule_mode: true,
    },
  };
}
