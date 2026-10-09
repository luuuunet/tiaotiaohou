import assert from "node:assert/strict";
import { blockReason, tokenOk } from "../src/guard.ts";

assert.equal(blockReason("example.com", 443), null);
assert.equal(blockReason("1.1.1.1", 853), null);
assert.equal(blockReason("127.0.0.1", 80), "内网地址不能转发");
assert.equal(blockReason("10.0.0.1", 443), "内网地址不能转发");
assert.equal(blockReason("192.168.1.1", 443), "内网地址不能转发");
assert.equal(blockReason("172.16.5.5", 443), "内网地址不能转发");
assert.equal(blockReason("169.254.1.1", 443), "内网地址不能转发");
assert.equal(blockReason("100.64.1.1", 443), "内网地址不能转发");
assert.equal(blockReason("localhost", 443), "内网地址不能转发");
assert.equal(blockReason("::1", 443), "内网地址不能转发");
assert.equal(blockReason("example.com", 25), "这个端口不能转发");
assert.equal(blockReason("bad host", 443), "主机名不合法");

const ok = await tokenOk("same-token", "same-token");
const bad = await tokenOk("nope", "same-token");
const empty = await tokenOk("same-token", "");
assert.equal(ok, true);
assert.equal(bad, false);
assert.equal(empty, false);

console.log("guard ok");
