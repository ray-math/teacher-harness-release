// Behavioral tests for the generated script. No real browser/profile is controlled.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const generator = fs.readFileSync(path.join(__dirname, 'Update-HumanWorkConsole.ps1'), 'utf8');
const script = generator.match(/  <script>\s*([\s\S]+?)\s*<\/script>/)[1];

function setup(protocol = 'file:') {
  const listeners = new Map(), elements = new Map(), timers = [], navigations = [], reloads = [], markers = [];
  let now = 0;
  class Element {
    constructor(id, attrs = {}) { this.id = id; this.attrs = attrs; this.listeners = {}; this.hidden = true; elements.set(id, this); }
    getAttribute(k) { return this.attrs[k]; }
    setAttribute(k, v) { this.attrs[k] = String(v); }
    removeAttribute(k) { delete this.attrs[k]; }
    get href() { return this.attrs.href; }
    set href(v) { this.attrs.href = v; }
    addEventListener(type, fn) { this.listeners[type] = fn; }
    click(options = {}) {
      const event = {button: 0, ...options, preventDefault() { this.defaultPrevented = true; }};
      this.listeners.click?.(event);
      if (!event.defaultPrevented && this.href) navigations.push(this.href);
      return event;
    }
    focus() {}
    remove() {}
  }
  const refresh = new Element('refresh-console', {href: 'hwpx-work-open:refresh/fixture'});
  const status = new Element('console-action-status');
  const file = new Element('file', {href:'hwpx-work-open://open/fixture'});
  const tabs = [0, 1, 2].map(i => {
    new Element('work-panel-' + i);
    return new Element('work-tab-' + i, {'aria-controls': 'work-panel-' + i});
  });
  const tabList = new Element('tablist');
  const location = {protocol, href: 'file:///C:/work/console.html#work-tab-2', hash: '#work-tab-2', replace: value => reloads.push(value)};
  const window = {};
  const document = {
    getElementById: id => elements.get(id),
    querySelectorAll: query => query === '[role="tab"]' ? tabs : query === 'a.file-link' ? [file] : [],
    querySelector: () => tabList,
    addEventListener: (type, fn) => listeners.set(type, fn),
    createElement: () => new Element('marker-' + markers.length),
    head: {appendChild: marker => markers.push(marker)},
  };
  vm.runInNewContext(script, {document, location, window, crypto: webcrypto, Uint8Array, URL,
    Date: {now: () => now}, setTimeout: fn => timers.push(fn)});
  return {refresh, file, status, tabs, window, location, markers, timers, navigations, reloads,
    tick: () => timers.shift()?.(), advance: value => { now += value; },
    key: key => { const event = {key, preventDefault() { this.defaultPrevented = true; }}; listeners.get('keydown')(event); return event; }};
}

const checks = [];
let app = setup();
assert.equal(app.tabs[2].getAttribute('aria-selected'), 'true');
checks.push('selected tab restored from URL hash');
const click = app.refresh.click();
assert.equal(click.defaultPrevented, undefined);
assert.match(app.navigations[0], /^hwpx-work-open:refresh\/fixture\/[a-f0-9]{32}$/);
checks.push('title click uses native anchor default navigation with a request nonce');
assert.equal(app.refresh.click().defaultPrevented, true);
assert.equal(app.navigations.length, 1);
checks.push('concurrent refresh click does not dispatch twice');
const requestId = app.navigations[0].split('/').at(-1);
app.tick(); app.window.__hwpxConsoleRefresh = {requestId: 'old', ok: true}; app.markers.at(-1).onload();
assert.equal(app.reloads.length, 0);
app.tick(); app.window.__hwpxConsoleRefresh = {requestId, ok: true}; app.markers.at(-1).onload();
const next = new URL(app.reloads[0]);
assert.equal(next.searchParams.get('refresh'), requestId); assert.equal(next.hash, '#work-tab-2');
checks.push('only matching success reloads a fresh URL and retains the tab');
app = setup(); assert.equal(app.key('F5').defaultPrevented, true); assert.equal(app.navigations.length, 1);
checks.push('F5 invokes the same anchor action');
app.tick(); app.window.__hwpxConsoleRefresh = {requestId: app.navigations[0].split('/').at(-1), ok: false}; app.markers.at(-1).onload();
assert.equal(app.reloads.length, 0); app.refresh.click(); assert.equal(app.navigations.length, 2);
checks.push('failed completion permits retry without a false reload');
app = setup(); app.refresh.click(); app.advance(30001); app.tick(); assert.equal(app.reloads.length, 0);
app.refresh.click(); assert.equal(app.navigations.length, 2);
checks.push('timeout is bounded and permits a new request');
app = setup('https:'); assert.equal(app.refresh.click().defaultPrevented, true); assert.equal(app.navigations.length, 0);
checks.push('non-local page cannot dispatch refresh');
app=setup();app.file.click();
assert.match(app.navigations[0],/^hwpx-work-open:\/\/open\/fixture\/[a-f0-9]{32}$/);
app.tick();app.window.__hwpxConsoleOpen={requestId:'stale',ok:true};app.markers.at(-1).onload();
assert.doesNotMatch(app.status.textContent,/Windows가/);
app.tick();app.window.__hwpxConsoleOpen={requestId:app.navigations[0].split('/').at(-1),ok:true};app.markers.at(-1).onload();
assert.match(app.status.textContent,/Windows가/);
checks.push('file open accepts only matching Windows dispatch acknowledgement');
app=setup();app.file.click();app.advance(15001);app.tick();
assert.match(app.status.textContent,/요청 코드/);assert.doesNotMatch(app.status.textContent,/확인창|차단/);
app.file.click();assert.equal(app.navigations.length,2);
checks.push('file timeout reports correlation code without guessing browser permissions and permits retry');
app=setup();app.file.click();app.tick();
app.window.__hwpxConsoleOpen={requestId:app.navigations[0].split('/').at(-1),ok:false,stage:'validate',code:'missing_file'};
app.markers.at(-1).onload();
assert.match(app.status.textContent,/missing_file/);assert.match(app.status.textContent,/validate/);
assert.doesNotMatch(app.status.textContent,/Windows가/);
checks.push('native failure displays stage and code in the HTML');
console.log(JSON.stringify({ok: true, count: checks.length, checks}, null, 2));
