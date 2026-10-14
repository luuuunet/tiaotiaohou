import { DEFAULT_PORT, NATIVE_HOST, browserConfig, coreReply, normalizePort, proxyAlreadyApplied, proxyConfig } from './proxy_rules.js';

const MISS_LIMIT = 2;
let misses = 0;

async function readState() {
  const saved = await chrome.storage.local.get({
    running: false,
    port: DEFAULT_PORT,
    endpoint: '',
    token: '',
    secret: '',
    detail: '先双击启动.bat，再填节点地址和令牌',
  });
  let secret = String(saved.secret || '');
  if (!/^[0-9a-f]{32,128}$/i.test(secret)) {
    const bytes = new Uint8Array(24);
    crypto.getRandomValues(bytes);
    secret = [...bytes].map((item) => item.toString(16).padStart(2, '0')).join('');
    await chrome.storage.local.set({ secret });
  }
  const port = normalizePort(saved.port) ?? DEFAULT_PORT;
  return {
    running: Boolean(saved.running),
    port,
    endpoint: String(saved.endpoint || ''),
    token: String(saved.token || ''),
    secret,
    detail: String(saved.detail || ''),
  };
}

function publicState(state) {
  const copy = { ...state };
  delete copy.secret;
  return copy;
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
    const body = await res.text();
    return coreReply(res.status, body);
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function applyProxy(port) {
  const current = await chrome.proxy.settings.get({});
  if (current.levelOfControl === 'controlled_by_other_extensions' || current.levelOfControl === 'not_controllable') {
    throw new Error('浏览器代理被别的扩展或策略占用了');
  }
  if (!proxyAlreadyApplied(current, port)) {
    await chrome.proxy.settings.set({
      value: proxyConfig(port),
      scope: 'regular',
    });
  }
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

function explainNative(text) {
  const raw = String(text || '');
  if (/not found/i.test(raw) || raw === '') return '还没登记核心。请先双击压缩包里的启动.bat';
  if (/forbidden|access/i.test(raw)) return '浏览器不让这个扩展启动核心。请重新双击启动.bat，并加载 extension 文件夹';
  return raw;
}

function talkNative(message) {
  return new Promise((resolve, reject) => {
    let port;
    try {
      port = chrome.runtime.connectNative(NATIVE_HOST);
    } catch (err) {
      reject(new Error(explainNative(err instanceof Error ? err.message : '')));
      return;
    }
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { port.disconnect(); } catch { /* 主机可能已经退出 */ }
      fn(value);
    };
    const timer = setTimeout(() => finish(reject, new Error('核心没有回应')), 20000);
    port.onMessage.addListener((msg) => {
      if (msg && msg.ok) finish(resolve, msg);
      else finish(reject, new Error((msg && msg.error) || '核心启动失败'));
    });
    port.onDisconnect.addListener(() => {
      const last = chrome.runtime.lastError && chrome.runtime.lastError.message;
      finish(reject, new Error(explainNative(last)));
    });
    try {
      port.postMessage(message);
    } catch (err) {
      finish(reject, new Error(explainNative(err instanceof Error ? err.message : '')));
    }
  });
}

async function connect(fields) {
  const built = browserConfig(fields);
  const keep = {
    endpoint: String(fields?.endpoint || '').trim(),
    token: String(fields?.token || ''),
    port: normalizePort(fields?.port) ?? DEFAULT_PORT,
  };
  if (built.error) {
    await clearProxy();
    misses = 0;
    return setState({ running: false, ...keep, detail: built.error });
  }
  const state = await readState();
  try {
    await talkNative({ type: 'start', secret: state.secret, config: built.config });
  } catch (err) {
    await clearProxy();
    misses = 0;
    return setState({
      running: false,
      endpoint: built.endpoint,
      token: built.token,
      port: built.port,
      detail: err instanceof Error ? err.message : '核心启动失败',
    });
  }
  const up = await probe(built.port);
  if (!up) {
    await clearProxy();
    misses = 0;
    return setState({
      running: false,
      endpoint: built.endpoint,
      token: built.token,
      port: built.port,
      detail: '核心没有按预期在本机听。请再点一次开始连接。',
    });
  }
  try {
    await applyProxy(built.port);
  } catch (err) {
    try { await clearProxy(); } catch { /* 清不掉就只把失败告诉用户 */ }
    misses = 0;
    return setState({
      running: false,
      endpoint: built.endpoint,
      token: built.token,
      port: built.port,
      detail: err instanceof Error ? err.message : '浏览器代理没有设上',
    });
  }
  misses = 0;
  return setState({
    running: true,
    endpoint: built.endpoint,
    token: built.token,
    port: built.port,
    detail: `浏览器正在走 127.0.0.1:${built.port}`,
  });
}

async function disconnect() {
  const state = await readState();
  try {
    await talkNative({ type: 'stop', secret: state.secret });
  } catch {
    // 核心已经不在时，浏览器仍然要放开。
  }
  await clearProxy();
  misses = 0;
  return setState({
    running: false,
    port: state.port,
    endpoint: state.endpoint,
    token: state.token,
    detail: '浏览器已断开，核心也停了。',
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
    try {
      await applyProxy(state.port);
    } catch {
      // 这一轮设不上就等下一次，不要把正在用的浏览器掐掉。
    }
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
    if (message?.type === 'state') return publicState(await readState());
    if (message?.type === 'connect') return publicState(await connect(message));
    if (message?.type === 'disconnect') return publicState(await disconnect());
    return publicState(await readState());
  };
  run().then(sendResponse, (err) => {
    sendResponse({
      running: false,
      port: DEFAULT_PORT,
      detail: err instanceof Error ? err.message : '扩展内部出错了',
    });
  });
  return true;
});
