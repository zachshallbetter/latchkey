const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function fixture({ missing = false, refuse = false } = {}) {
  let clicked, incoming, sends = 0, preparations = 0;
  const calls = [], badges = [], titles = [];
  const browser = {
    runtime: { onMessage: { addListener(fn) { incoming = fn; } }, onInstalled: { addListener() {} }, onStartup: { addListener() {} } },
    menus: { removeAll: () => Promise.resolve(), create() {}, onClicked: { addListener(fn) { clicked = fn; } } },
    tabs: {
      sendMessage(tab, message, options) {
        calls.push({ tab, message, options }); sends++;
        return missing && sends === 1 ? Promise.reject(new Error('No receiver')) : Promise.resolve(true);
      }
    },
    scripting: { executeScript(options) {
      assert.equal(options.target.tabId, 23);
      assert.deepEqual(Array.from(options.target.frameIds), [0]);
      assert.deepEqual(Array.from(options.files), ['browser-config.js', 'browser-api.js', 'detector.js', 'content.js']);
      preparations++; return refuse ? Promise.reject(new Error('Restricted page')) : Promise.resolve();
    } },
    action: { setBadgeText(x) { badges.push(x); }, setTitle(x) { titles.push(x); } }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../Safari/Resources/background.js'), 'utf8'), { browser, URL, PistachioBrowserConfig: { target: "chrome" } });
  return {
    async click(info = {}) { clicked({ menuItemId: 'lk-save-selection', selectionText: 'fixture-selected-text', frameId: 0, ...info }, { id: 23 }); await new Promise(setImmediate); },
    calls, badges, titles, preparations: () => preparations,
    error: () => incoming({ op: 'selection-status', tabId: 23 }, {})
  };
}

test('context menu forwards browser-captured selection to the top-frame save panel', async () => {
  const f = fixture(); await f.click();
  assert.equal(f.calls.length, 1);
  assert.equal(f.calls[0].message.selectionText, 'fixture-selected-text');
  assert.equal(f.calls[0].options.frameId, 0);
  assert.equal(f.preparations(), 0);
  assert.equal((await f.error()).error, '');
});

test('an existing tab without a listener is prepared once then retried', async () => {
  const f = fixture({ missing: true }); await f.click();
  assert.equal(f.preparations(), 1);
  assert.equal(f.calls.length, 2);
  assert.equal(f.calls[1].message.selectionText, f.calls[0].message.selectionText);
  assert.equal((await f.error()).error, '');
});

test('restricted-page failure gives static recovery guidance without selected text', async () => {
  const f = fixture({ missing: true, refuse: true }); await f.click();
  assert.equal(f.calls.length, 1);
  assert.equal(f.badges.at(-1).text, '!');
  const error = (await f.error()).error;
  assert.match(error, /Reload this page/);
  assert.ok(!error.includes('fixture-selected-text'));
  assert.ok(!f.titles.at(-1).title.includes('fixture-selected-text'));
});

test('oversized or framed selections are refused before dispatch or injection', async () => {
  for (const info of [{ selectionText: 'x'.repeat(16385) }, { frameId: 2 }, { selectionText: '' }]) {
    const f = fixture(); await f.click(info);
    assert.equal(f.calls.length, 0); assert.equal(f.preparations(), 0);
    assert.equal(f.badges.at(-1).text, '!');
  }
});

test('selection recovery guidance survives a later successful connection response', async () => {
  const native = Promise.withResolvers();
  const status = {}, none = {};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../Safari/Resources/popup.js'), 'utf8'), {
    document: { getElementById(id) { return id === 'status' ? status : none; } },
    browser: {
      runtime: { sendNativeMessage: () => native.promise, sendMessage: () => Promise.resolve({ error: 'Reload this page and try again.' }) },
      tabs: { query: () => Promise.resolve([{ id: 23 }]), sendMessage: () => Promise.resolve([]) }
    }
  });
  await new Promise(setImmediate);
  native.resolve({ ok: true });
  await new Promise(setImmediate);
  assert.equal(status.className, 'status no');
  assert.equal(status.textContent, 'Reload this page and try again.');
});
