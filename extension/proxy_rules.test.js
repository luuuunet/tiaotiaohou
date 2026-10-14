import assert from 'node:assert/strict';
import test from 'node:test';

import { bypassList, coreIsUp, normalizePort, proxyConfig } from './proxy_rules.js';

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
});

test('any http reply means the local core is listening', () => {
  assert.equal(coreIsUp(405), true);
  assert.equal(coreIsUp(200), true);
  assert.equal(coreIsUp(0), false);
  assert.equal(coreIsUp(undefined), false);
});
