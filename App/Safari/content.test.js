// Content-script lifecycle tests with a small DOM fixture; no real browser, pages or credentials.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function fixture(values, options = {}) {
  const events = {}, windowEvents = {}, timers = [];
  let onMessage, reads = 0;
  const contexts = [], messages = [];
  const fields = values.map(value => ({
    nodeType: 1, connected: true, type: 'text', stored: value, id: '', children: [],
    get value() { reads++; return this.stored; },
    getAttribute(name) { return (options.attributes || {})[name] || null; }, closest() { return null; }, querySelectorAll() { return []; },
    matches(selector) {
      if (selector === 'input[type=password], input[type=hidden]') return ['password', 'hidden'].includes(this.type);
      if (selector.includes('input:not')) return !['password', 'hidden'].includes(this.type);
      return false;
    }
  }));
  const body = {
    nodeType: 1, connected: true, matches() { return false; },
    querySelectorAll(selector) { return selector.includes('input:not') ? fields.filter(f => f.matches(selector)) : []; }
  };
  const group = options.nearby ? {
    nodeType: 1, connected: true, parentElement: body, innerText: options.nearby,
    matches() { return true; }, firstElementChild: null
  } : body;
  body.innerText = options.bodyText || '';
  fields.forEach(f => { f.parentElement = group; });
  const document = {
    body, title: options.title || "", documentElement: body, contains(el) { return el.connected; },
    querySelector() { return null; }, getElementById() { return null; },
    createTreeWalker() { return { nextNode() { return null; } }; },
    addEventListener(name, fn) { events[name] = fn; }
  };
  const window = {
    LatchkeyDetector: {
      findAll(text, context) { contexts.push(context); return [{ value: text, type: 'Fixture', confidence: 'medium', service: '', name: 'KEY', kind: 'token' }]; },
      preview(text) { return text.slice(0, 6) + '…' + text.slice(-4); }
    },
    addEventListener(name, fn) { windowEvents[name] = fn; }
  };
  window.top = window;
  const location = { href: 'https://fixture.example/keys', hostname: 'fixture.example', pathname: '/credentials' };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'Resources/content.js'), 'utf8'), {
    window, document, location, CSS: { escape: x => x },
    NodeFilter: { SHOW_TEXT: 4, FILTER_REJECT: 2, FILTER_ACCEPT: 1 },
    MutationObserver: class { observe() {} },
    browser: { runtime: { sendMessage: message => { messages.push(message); return Promise.resolve(); }, onMessage: { addListener(fn) { onMessage = fn; } } } },
    setTimeout(fn) { timers.push(fn); return timers.length; }, setInterval() {}, requestAnimationFrame(fn) { fn(); }
  });
  return { fields, events, windowEvents, location, contexts, messages, reads: () => reads,
    detections: () => onMessage({ op: 'detections' }),
    flush() { while (timers.length) timers.shift()(); } };
}

test('changed values are pruned and re-detected; detached values are removed', async () => {
  const f = fixture(['fixture-original-key-1234']);
  assert.equal((await f.detections()).length, 1);
  f.fields[0].stored = 'fixture-replacement-key-5678';
  assert.equal((await f.detections()).length, 0);
  f.events.input({ target: f.fields[0] }); f.flush();
  const next = await f.detections();
  assert.equal(next.length, 1);
  assert.ok(next[0].preview.endsWith('5678'));
  f.fields[0].connected = false;
  assert.equal((await f.detections()).length, 0);
});

test('password and hidden fields are never read by focus/input handlers', async () => {
  const f = fixture(['fixture-original-key-1234']);
  for (const type of ['password', 'hidden']) {
    f.fields[0].type = type;
    const before = f.reads();
    f.events.focusin({ target: f.fields[0] });
    f.events.input({ target: f.fields[0] }); f.flush();
    assert.equal((await f.detections()).length, 0);
    assert.equal(f.reads(), before);
  }
});

test('navigation and pagehide discard captures; retained candidates are bounded', async () => {
  const f = fixture(Array.from({ length: 130 }, (_, i) => 'fixture-candidate-key-' + String(i).padStart(4, '0')));
  assert.equal((await f.detections()).length, 100);
  f.location.href = 'https://fixture.example/other';
  assert.equal((await f.detections()).length, 0);
  f.events.focusin({ target: f.fields[0] });
  assert.equal((await f.detections()).length, 1);
  f.windowEvents.pagehide();
  assert.equal((await f.detections()).length, 0);
});


test('DOM context uses bounded local groups and omits page body and URL query data', () => {
  const f = fixture(['fixture-original-key-1234'], {
    attributes: { 'aria-label': 'Client secret' }, nearby: 'Client secret. Copy your key now.',
    title: 'Create API key', bodyText: 'Unrelated API keys and project IDs elsewhere on the page'
  });
  assert.equal(f.contexts[0].label, 'Client secret');
  assert.equal(f.contexts[0].nearby, 'Client secret. Copy your key now.');
  assert.equal(f.contexts[0].title, 'Create API key');
  assert.equal(f.contexts[0].path, '/credentials');
  assert.ok(!Object.hasOwn(f.contexts[0], 'href'));
  assert.ok(f.messages.every(message => message.op === 'count' && !Object.hasOwn(message, 'context')));
  const broad = fixture(['fixture-original-key-1234'], { bodyText: 'Your new API key. Copy it now.' });
  assert.equal(broad.contexts[0].nearby, '', 'whole-body wording is not local evidence');
});
