import { DEFAULT_PORT, coreIsUp, normalizePort, proxyConfig } from './proxy_rules.js';

const MISS_LIMIT = 2;
let misses = 0;

async function readState() {
  const saved = await chrome.storage.local.get({
    running: false,
    port: DEFAULT_PORT,
    detail: '还没有让浏览器走跳跳猴',
  });
  const port = normalizePort(saved.port) ?? DEFAULT_PORT;
  return { running: Boolean(saved.running), port, detail: String(saved.detail || '') };
}

async function probe(port) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 2000);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/`, {
      method: 'GET',
      cache: 'no-store',
      signal: ctrl.signal,
    });
    return coreIsUp(res.status);
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function applyProxy(port) {
  await chrome.proxy.settings.set({
    value: proxyConfig(port),
    scope: 'regular',
  });
  try {
    await chrome.privacy.network.webRTCIPHandlingPolicy.set({
      value: 'disable_non_proxied_udp',
      scope: 'regular',
    });
  } catch {
    // 企业策略可能锁住这项。浏览器代理仍然有效。
  }
}

async function clearProxy() {
  await chrome.proxy.settings.clear({ scope: 'regular' });
  try {
    await chrome.privacy.network.webRTCIPHandlingPolicy.clear({ scope: 'regular' });
  } catch {
    // 清不掉也不要挡住断开。
  }
}

async function setState(patch) {
  await chrome.storage.local.set(patch);
  return readState();
}

async function connect(port) {
  const safe = normalizePort(port);
  if (safe == null) {
    return setState({ running: false, detail: '端口不对，请填 1 到 65535' });
  }
  const up = await probe(safe);
  if (!up) {
    await clearProxy();
    misses = 0;
    return setState({
      running: false,
      port: safe,
      detail: `127.0.0.1:${safe} 没有在听。请先打开跳跳猴，点开始连接。`,
    });
  }
  await applyProxy(safe);
  misses = 0;
  return setState({
    running: true,
    port: safe,
    detail: `浏览器正在走 127.0.0.1:${safe}。关掉跳跳猴后，这里会自动放开。`,
  });
}

async function disconnect() {
  await clearProxy();
  misses = 0;
  const state = await readState();
  return setState({
    running: false,
    port: state.port,
    detail: '浏览器已断开。跳跳猴如果还开着，其它软件仍可能在走。',
  });
}

async function watch() {
  const state = await readState();
  if (!state.running) {
    misses = 0;
    return;
  }
  if (await probe(state.port)) {
    misses = 0;
    await applyProxy(state.port);
    return;
  }
  misses += 1;
  if (misses < MISS_LIMIT) return;
  misses = 0;
  await clearProxy();
  await setState({
    running: false,
    detail: '本机代理没了，浏览器已放开，避免网页打不开。',
  });
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create('watch', { periodInMinutes: 1 });
  watch();
});

chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create('watch', { periodInMinutes: 1 });
  watch();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'watch') watch();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  const run = async () => {
    if (message?.type === 'state') return readState();
    if (message?.type === 'connect') return connect(message.port);
    if (message?.type === 'disconnect') return disconnect();
    return readState();
  };
  run().then(sendResponse);
  return true;
});
