import assert from 'node:assert/strict';
import test from 'node:test';

import fs from 'node:fs';
import crypto from 'node:crypto';

import { browserConfig, bypassList, coreReply, normalizePort, proxyAlreadyApplied, proxyConfig, NATIVE_HOST } from './proxy_rules.js';

test('port stays on a real local listener', () => {
  assert.equal(normalizePort('8080'), 8080);
  assert.equal(normalizePort(1080), 1080);
  assert.equal(normalizePort('0'), null);
  assert.equal(normalizePort('65536'), null);
  assert.equal(normalizePort('abc'), null);
  assert.equal(normalizePort(''), null);
});

test('browser proxy is only 127.0.0.1 http', () => {
  const config = proxyConfig(8080);
  assert.equal(config.mode, 'fixed_servers');
  assert.deepEqual(config.rules.singleProxy, {
    scheme: 'http',
    host: '127.0.0.1',
    port: 8080,
  });
  assert.ok(config.rules.bypassList.includes('127.0.0.1'));
  assert.ok(config.rules.bypassList.includes('<local>'));
  assert.ok(config.rules.bypassList.includes('192.168.0.0/16'));
  assert.equal(bypassList().includes('*'), false);
  assert.equal(bypassList().includes('<all_urls>'), false);
  assert.equal(bypassList().includes('::1'), false);
  assert.ok(bypassList().includes('[::1]'));
});

test('only the local connect-only proxy counts as tiaotiaohou', () => {
  assert.equal(coreReply(405, 'only CONNECT'), true);
  assert.equal(coreReply(405, 'other'), false);
  assert.equal(coreReply(200, 'only CONNECT'), false);
  assert.equal(coreReply(0, ''), false);
});

test('browser config is the same shape the core accepts', () => {
  const bad = browserConfig({ endpoint: 'http://example.com', token: 'abc', port: 8080 });
  assert.equal(bad.error, '节点必须是 https:// 开头');
  const path = browserConfig({ endpoint: 'https://example.com/rsq', token: 'abc', port: 8080 });
  assert.equal(path.error, '节点地址不要带路径');
  const built = browserConfig({ endpoint: 'https://example.com', token: 'abc', port: '8080' });
  assert.equal(built.error, undefined);
  assert.equal(built.config.http_port, 8080);
  assert.equal(built.config.socks_port, 1080);
  assert.equal(built.config.fetch_enabled, false);
  assert.equal(built.config.exit_via, 'landing');
  assert.equal(built.config.rule_mode, true);
  const swapped = browserConfig({ endpoint: 'https://example.com', token: 'abc', port: 1080 });
  assert.equal(swapped.config.socks_port, 1081);
});

test('the extension id matches the host the core registers', () => {
  const manifest = JSON.parse(fs.readFileSync(new URL('./manifest.json', import.meta.url), 'utf8'));
  const der = Buffer.from(manifest.key, 'base64');
  const hex = crypto.createHash('sha256').update(der).digest('hex').slice(0, 32);
  const id = [...hex].map((item) => String.fromCharCode('a'.charCodeAt(0) + Number.parseInt(item, 16))).join('');
  assert.equal(id, 'mjgdoiafgphhklklnfloinljmlekfjad');
  assert.ok(manifest.permissions.includes('nativeMessaging'));
  assert.ok(manifest.host_permissions.includes('http://127.0.0.1:*/*'));
  const rust = fs.readFileSync(new URL('../core/src/bin/tiaotiaohou_browser.rs', import.meta.url), 'utf8');
  assert.ok(rust.includes(`chrome-extension://${id}/`));
  assert.ok(rust.includes(NATIVE_HOST));
});

test('an existing matching proxy is not set again', () => {
  const same = proxyConfig(8080);
  assert.equal(proxyAlreadyApplied({ value: same }, 8080), true);
  assert.equal(proxyAlreadyApplied({ value: proxyConfig(1080) }, 8080), false);
  assert.equal(proxyAlreadyApplied({ value: { mode: 'system' } }, 8080), false);
});
