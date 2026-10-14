import assert from 'node:assert/strict';
import test from 'node:test';

import { bypassList, coreReply, normalizePort, proxyAlreadyApplied, proxyConfig } from './proxy_rules.js';

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

test('an existing matching proxy is not set again', () => {
  const same = proxyConfig(8080);
  assert.equal(proxyAlreadyApplied({ value: same }, 8080), true);
  assert.equal(proxyAlreadyApplied({ value: proxyConfig(1080) }, 8080), false);
  assert.equal(proxyAlreadyApplied({ value: { mode: 'system' } }, 8080), false);
});
