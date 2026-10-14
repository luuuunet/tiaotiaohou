export const DEFAULT_PORT = 8080;

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
