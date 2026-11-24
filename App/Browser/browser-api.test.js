const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'browser-api.js'), 'utf8');

function fixture(target) {
  let listener, native, fail = false;
  const event = { addListener() {} };
  const runtime = {
    onMessage: { addListener(fn) { listener = fn; } }, onInstalled: event, onStartup: event,
    sendNativeMessage(host, message, done) {
      native = { host, message };
      if (target === 'firefox') return fail ? Promise.reject(new Error('private native details')) : Promise.resolve({ ok: true });
      runtime.lastError = fail ? { message: 'private native details' } : undefined;
      done(fail ? undefined : { ok: true }); runtime.lastError = undefined;
    },
    sendMessage(message, done) { if (done) done({ ok: true }); else return Promise.resolve({ ok: true }); }
  };
  const api = { runtime, action: {}, tabs: {}, contextMenus: { removeAll() {}, create() {}, onClicked: event } };
  const context = { Promise, Error, PistachioBrowserConfig: { target, host: 'io.snackstud.pistachio' } };
  context[target === 'chrome' ? 'chrome' : 'browser'] = api;
  vm.runInNewContext(source, context);
  return { api: context.PistachioBrowserAPI, listener: () => listener, native: () => native, fail: () => { fail = true; } };
}

for (const target of ['chrome', 'firefox']) {
  test(target + ': native requests are versioned and failures hide raw details', async () => {
    const f = fixture(target);
    assert.equal((await f.api.runtime.sendNativeMessage('old-safari-host', { op: 'status' })).ok, true);
    assert.equal(f.native().host, 'io.snackstud.pistachio');
    assert.equal(f.native().message.version, 1);
    assert.equal(f.native().message.message.op, 'status');
    f.fail();
    const response = await f.api.runtime.sendNativeMessage('ignored', { op: 'status' });
    assert.equal(response.ok, false);
    assert.ok(!response.error.includes('private native details'));
  });
}

test('Chrome keeps asynchronous message channels alive without claiming unrelated messages', async () => {
  const f = fixture('chrome');
  f.api.runtime.onMessage.addListener(message => message.op === 'handled' ? Promise.resolve({ ok: true }) : undefined);
  let reply;
  assert.equal(f.listener()({ op: 'handled' }, {}, value => { reply = value; }), true);
  await Promise.resolve(); await Promise.resolve();
  assert.equal(reply.ok, true);
  assert.equal(f.listener()({ op: 'unrelated' }, {}, () => assert.fail('unrelated response')), undefined);
});
