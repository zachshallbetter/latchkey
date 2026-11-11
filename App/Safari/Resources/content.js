// Finds keys and tokens on the page with Latchkey's detector (detector.js) and offers to save them. Confident finds
// get a small "Save to Latchkey" button next to the key itself; less certain ones are listed in the toolbar panel.
// Values stay in this page until you press Save, and then go only to the Latchkey app, which asks you first. The
// toolbar panel sees previews, never values.
(function () {
  "use strict";
  var D = window.LatchkeyDetector;
  if (!D || window.top !== window) return;

  var found = [];            // { id, result, element }
  var byValue = new Map();
  var nextID = 1;
  var pills = new Map();     // detection id → host element of its button
  var panelHost = null;
  var pageURL = location.href;
  var FIELDS = "input:not([type=password]):not([type=hidden]), textarea";
  var MAX_FOUND = 100;
  var UNREACHABLE = "Couldn't reach Latchkey. Reload this page; if that doesn't help, open the Latchkey app.";

  // ---- Where to look, and the words around a value
  var SKIP = "script,style,noscript,svg,template,[contenteditable=true]";
  function labelFor(el) {
    if (!el || el.nodeType !== 1) return "";
    var bits = [el.getAttribute("aria-label"), el.getAttribute("name"), el.id, el.getAttribute("data-testid")];
    if (el.id) { var l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (l) bits.push(l.textContent); }
    var lab = el.closest("label"); if (lab) bits.push(lab.textContent);
    var labelledby = el.getAttribute("aria-labelledby");
    if (labelledby) labelledby.split(/\s+/).forEach(function (id) { var t = document.getElementById(id); if (t) bits.push(t.textContent); });
    // The nearest heading or label-like text just before it.
    var prev = el.previousElementSibling;
    for (var i = 0; prev && i < 3; i++, prev = prev.previousElementSibling) { if (prev.textContent && prev.textContent.length < 80) { bits.push(prev.textContent); break; } }
    var parent = el.parentElement;
    if (parent && parent.firstElementChild !== el && parent.firstElementChild && parent.firstElementChild.textContent.length < 80) bits.push(parent.firstElementChild.textContent);
    return bits.filter(Boolean).join(" ").replace(/\s+/g, " ").slice(0, 200);
  }
  function nearbyFor(el) {
    var box = el.closest('[role="dialog"], dialog, [aria-modal="true"], .modal, form, section, article') || el.parentElement;
    return box ? (box.innerText || box.textContent || "").slice(0, 1500) : "";
  }
  function contextFor(el, field) {
    return { label: labelFor(el), nearby: nearbyFor(el), host: location.hostname, field: field };
  }

  function visible(el) {
    if (!el || !document.contains(el)) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    var doc = document.documentElement;
    if (r.right + window.scrollX <= 0 || r.bottom + window.scrollY <= 0 || r.left + window.scrollX >= doc.scrollWidth) return false;
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
    var cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.opacity === "0") return false;
    // On screen, it must be what you'd hit there: not clipped away or covered.
    var x = r.left + Math.min(r.width / 2, 12), y = r.top + r.height / 2;
    if (x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight) return true;
    var hit = document.elementFromPoint(x, y);
    return !!hit && (hit === el || el.contains(hit));
  }
  // Where a key's button goes: the first copy you can see. A page may hold others (a hidden copy for its copy button).
  function anchorOf(d) {
    d.elements = (d.elements || [d.element]).filter(function (e) { return document.contains(e); });
    var best = null, area = Infinity;
    d.elements.forEach(function (e) {
      if (!visible(e)) return;
      var r = e.getBoundingClientRect(), a = r.width * r.height;
      if (a < area) { best = e; area = a; }
    });
    if (best) d.element = best;
    return best;
  }
  function live(d) {
    var el = d.element;
    if (!document.contains(el) || el.matches("input[type=password], input[type=hidden]")) return false;
    var text = el.matches(FIELDS) ? el.value : (el.innerText || el.textContent || "");
    return !!d.result.value && text.includes(d.result.value);
  }
  function retire(d) {
    byValue.delete(d.result.value);
    d.result.value = ""; // Panels may still close over this record; do not retain its old secret there.
    var pill = pills.get(d.id);
    if (pill) { pill.remove(); pills.delete(d.id); }
  }
  function prune() {
    var navigated = pageURL !== location.href;
    pageURL = location.href;
    found = found.filter(function (d) {
      if (!navigated && live(d)) return true;
      retire(d); return false;
    });
    if (navigated && panelHost) { panelHost.remove(); panelHost = null; }
  }

  function consider(text, el, field) {
    if (!text || text.length < 16 || el.matches("input[type=password], input[type=hidden]")) return;
    prune();
    D.findAll(text, contextFor(el, field)).forEach(function (r) {
      var seen = byValue.get(r.value);
      if (seen) {
        seen.elements = seen.elements || [seen.element];
        if (seen.elements.indexOf(el) < 0 && seen.elements.length < 12) seen.elements.push(el);
        return;
      }
      var d = { id: nextID++, result: r, element: el, elements: [el] };
      byValue.set(r.value, d);
      if (found.length >= MAX_FOUND) retire(found.shift());
      found.push(d);
      if (r.confidence === "high") showPill(d);
    });
  }

  function scan(root) {
    if (!root || root.nodeType !== 1 || (panelHost && panelHost.contains(root))) return;
    // Fields, code and cells, where keys are shown on purpose.
    var SHOWN = "code, pre, kbd, samp, td, [data-testid*=key i], [data-testid*=token i], [class*=secret i], [class*=token i], [class*=apikey i]";
    function within(sel) { var all = Array.from(root.querySelectorAll(sel)); if (root.matches(sel)) all.unshift(root); return all; }
    within(FIELDS).forEach(function (el) { consider(el.value, el, true); });
    within(SHOWN).forEach(function (el) {
      if (el.closest(SKIP) || el.children.length > 20) return;
      consider((el.innerText || el.textContent || "").slice(0, 8000), el, el.matches("code, pre, kbd, samp"));
    });
    // Plain text elsewhere: only runs of text that could hold a key.
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var t = n.nodeValue;
        if (!t || t.length < 20 || t.length > 8000 || !/[A-Za-z0-9_\-]{20,}/.test(t)) return NodeFilter.FILTER_REJECT;
        var p = n.parentElement;
        if (!p || p.closest(SKIP) || p.closest("code, pre, kbd, samp, td, textarea")) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    for (var n, count = 0; (n = walker.nextNode()) && count < 4000; count++) consider(n.nodeValue, n.parentElement, false);
    report();
  }

  function report() {
    prune();
    var shown = found;
    try { browser.runtime.sendMessage({ op: "count", count: shown.length }).catch(function () {}); } catch (e) {}
  }

  // Changes to the page: look again at what changed, a moment later. Fields filled by script don't always change the
  // page's structure, so focused fields are checked too.
  var pending = new Set(), timer = null;
  function later(node) {
    pending.add(node.nodeType === 1 ? node : node.parentElement);
    if (!timer) timer = setTimeout(function () {
      timer = null;
      var nodes = Array.from(pending); pending.clear();
      nodes.forEach(function (el) { if (el && document.contains(el)) scan(el); });
    }, 350);
  }
  new MutationObserver(function (records) {
    records.forEach(function (r) {
      if (panelHost && panelHost.contains(r.target)) return;
      if (r.type === "childList") r.addedNodes.forEach(later); else later(r.target);
    });
  }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
  document.addEventListener("focusin", function (e) { if (e.target.matches && e.target.matches(FIELDS)) { consider(e.target.value, e.target, true); report(); } }, true);
  document.addEventListener("input", function (e) { if (e.target.matches && e.target.matches(FIELDS)) later(e.target); }, true);

  // ---- The button beside a key
  var STYLE =
    ":host{all:initial}" +
    "*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,sans-serif}" +
    ".pill{display:inline-flex;align-items:center;gap:6px;padding:4px 10px 4px 7px;border-radius:999px;border:0;cursor:pointer;" +
    "background:#0a63d1;color:#fff;font:600 12px/1.2 -apple-system,sans-serif;box-shadow:0 4px 14px rgba(10,99,209,.35)}" +
    ".pill:hover{filter:brightness(1.08)}.pill:focus-visible{outline:2px solid #fff;outline-offset:-4px}" +
    ".pill svg{width:16px;height:13px;fill:#fff}" +
    "@keyframes lkin{from{opacity:0;transform:translateY(-6px) scale(.97)}}" +
    "@media (prefers-reduced-motion:reduce){.b{animation:none!important}}" +
    ".b{animation:lkin .16s ease-out;transform-origin:top right;font:13px/1.45 -apple-system,sans-serif;width:340px;padding:14px;border-radius:12px;background:#fff;color:#12161c;" +
    "border:1px solid #dde2e9;box-shadow:0 12px 32px rgba(16,24,40,.22)}" +
    "@media (prefers-color-scheme:dark){.b{background:#1c2128;color:#e8ecf1;border-color:#2f3640}.m{color:#a3adb9!important}input,select{background:#13181e!important;color:inherit!important;border-color:#2f3640!important}}" +
    "b.t{display:block;font-size:14px;margin-bottom:2px}.m{color:#5a6472;margin:0 0 10px}code{font:12px ui-monospace,Menlo,monospace}" +
    "label{display:block;font-weight:600;margin:8px 0 3px}select,input{width:100%;padding:6px 8px;border:1px solid #c9d0d9;border-radius:7px;font:13px -apple-system,sans-serif;background:#fff}" +
    ".r{display:flex;gap:8px;justify-content:flex-end;margin-top:12px}button.x{font:600 13px -apple-system,sans-serif;padding:6px 12px;border-radius:7px;border:1px solid #c9d0d9;background:transparent;color:inherit;cursor:pointer}" +
    "button.go{background:#0a63d1;border-color:#0a63d1;color:#fff}button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid #0a63d1;outline-offset:1px}" +
    ".s{margin:10px 0 0;min-height:1em}.hint{margin:4px 0 0;font-size:12px}.conf{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:5px;font-size:11px;font-weight:600;background:rgba(127,127,127,.18)}" +
    ".ref{display:flex;align-items:center;gap:8px;margin:0 0 8px;padding:6px 8px;border-radius:7px;background:rgba(127,127,127,.14)}.ref code{flex:1;overflow-wrap:anywhere}";
  var MARK = '<svg viewBox="0 0 717 593" aria-hidden="true"><path d="M342.1,38.8c44,0,80.7,31.7,88.6,73.4,13.5.7,27.4,1.8,40.8,2.8C463.9-1.1,298.7-42.9,235.9,53.6c16.1,1,31.3,4,45.5,8.7,16-14.6,37.3-23.5,60.7-23.5Z"/><path d="M330.5,268.6c-51.2-4.1-95.6-36.1-115.8-83.5-8.7-18.8,6.4-42.2,27-42,38.1,4.8,38.4,64.5,95.7,66.5,13.3,2,25.3-1.3,39.5-8.2C333.8-56.1-31.3,83.7,95.6,311.5c-3.5,20.6-22.2,36.4-26.6,56.8-1.6,31.5.2,26.6-22.8,43.5-11.3,11.7,10.1,36.6-8.6,42.3C18.7,459.9,0,511.6,0,515.9c0,5.2,10.3,74.3,16.6,76.9,12.3,1.2,60.6-16.6,83.5-26.7,18.1-22.6,88.4-153,108.5-185,4.2-8.9,14.9-6,22.9-7,76.7-3.9,123-50.9,139.5-107.2-13.2,2.6-27,3.3-40.4,1.8Z"/><path d="M707.7,298.3s-143.5-151.9-143.5-151.9c-22.6-24.2-61.5-17.1-92-21.3-65.3-7.1-85.7-6.2-81.2,67.6,23.7-15.2,19.3-30.5,37.8-38.8,13.6-6.1,31.1.2,37.7,13.5,16.5,37.7-43.6,82.8-74.6,93.5,1.5,11.1,4.9,21.5,12.4,30.3,3.8,4,140.6,149,145.3,153.9,16,14.7,39.8,15.6,56.5,2.2l98.7-92.6c15.3-14.9,16.6-40.8,2.9-56.5Z"/><path d="M457.6,191c12-23.3-22.3-42.1-35.1-18.6-12.7,23.3-48.1,48.1-77.6,47.7-42.9,1.7-68-30.7-86.2-56.6-7.2-8.5-14.3-13.1-23.9-9-10.5,4.1-15.4,16.2-10.9,26.6,18.3,43,58.9,73.6,107.6,77.4,50.8,5.9,102.9-22.2,126.1-67.7Z"/></svg>';

  function host(z) {
    var h = document.createElement("div");
    h.style.cssText = "position:fixed;z-index:" + z + ";top:0;left:0;";
    document.documentElement.appendChild(h);
    return h;
  }
  function place(h, el, below, alignRight) {
    var r = el.getBoundingClientRect();
    if (!below && (!visible(el) || r.bottom < 0 || r.top > window.innerHeight)) { h.style.display = "none"; return; }
    if (below && !visible(el)) {   // a panel whose key isn't on screen: bottom-right corner
      h.style.display = ""; h.style.left = Math.max(8, window.innerWidth - (h.offsetWidth || 340) - 16) + "px";
      h.style.top = Math.max(8, window.innerHeight - (h.offsetHeight || 260) - 16) + "px"; return;
    }
    h.style.display = "";
    var w = h.offsetWidth || 160, height = h.offsetHeight || 28;
    var left = Math.min(window.innerWidth - w - 8, Math.max(8, below && !alignRight ? r.left : r.right - w));
    var top = below ? r.bottom + 6 : r.top - height - 6;
    if (top < 8) top = r.bottom + 6;
    if (top + height > window.innerHeight - 8) top = Math.max(8, r.top - height - 6);
    h.style.left = left + "px"; h.style.top = top + "px";
  }

  function showPill(d) {
    if (pills.has(d.id)) return;
    var h = host(2147483646);
    var root = h.attachShadow({ mode: "closed" });
    root.innerHTML = "<style>" + STYLE + "</style><button class='pill' type='button'>" + MARK + "Save to Latchkey</button>";
    root.querySelector("button").setAttribute("aria-label", "Save this " + (d.result.service || "secret") + " to Latchkey");
    root.querySelector("button").addEventListener("click", function () { openPanel(d); });
    pills.set(d.id, h);
    var a = anchorOf(d);
    if (a) place(h, a, false); else h.style.display = "none";
  }
  function reposition() {
    prune();
    pills.forEach(function (h, id) {
      var d = found.find(function (x) { return x.id === id; });
      if (!d) { h.remove(); pills.delete(id); return; }
      var a = anchorOf(d);
      if (a) place(h, a, false); else h.style.display = "none";
    });
    offer();
    if (panelHost && panelHost._anchor) place(panelHost, panelHost._anchor, true, panelHost._fromPill);
  }
  // A key a page says it shows only once (a "your new key" dialog) gets the save panel without a click. Saving still
  // takes your press and Touch ID. Once per key, and never over a panel you have open.
  var offered = new Set();
  function offer() {
    if (panelHost) return;
    for (var i = 0; i < found.length; i++) {
      var d = found[i];
      if (d.result.confidence !== "high" || !d.result.shownOnce || offered.has(d.result.value)) continue;
      var a = anchorOf(d);
      if (!a) continue;
      offered.add(d.result.value);
      openPanel(d, a, true);
      return;
    }
  }
  var queued = false;
  function soon() { if (!queued) { queued = true; requestAnimationFrame(function () { queued = false; reposition(); }); } }
  window.addEventListener("scroll", soon, true);
  window.addEventListener("resize", soon);
  setInterval(reposition, 1000);   // dialogs move and close without scrolling

  // ---- Saving
  function openPanel(d, anchor, offeredByPage) {
    prune();
    if (!live(d)) return;
    if (panelHost) panelHost.remove();
    var r = d.result;
    var h = host(2147483647);
    if (r.confidence === "high" && d.id) showPill(d);
    var pill = pills.get(d.id);
    h._fromPill = !!pill && pill.style.display !== "none";
    h._anchor = h._fromPill ? pill : anchor || anchorOf(d) || d.element;
    var root = h.attachShadow({ mode: "closed" });
    var label = r.type + (r.environment ? " · " + (r.environment === "production" ? "live" : "test") : "");
    root.innerHTML = "<style>" + STYLE + "</style>" +
      '<div class="b" role="dialog" aria-label="Save to Latchkey">' +
      '<b class="t">Save to Latchkey?</b>' +
      '<p class="m"><span id="what"></span><span class="conf" id="conf"></span><br><code id="prev"></code></p>' +
      '<label for="lk-place">Where</label><select id="lk-place"><option value="">Shared (every project)</option></select>' +
      '<label for="lk-name">Name</label><input id="lk-name" autocomplete="off" spellcheck="false">' +
      '<p class="m hint" id="lk-hint"></p>' +
      '<div class="r"><button type="button" class="x" id="lk-no">Not now</button><button type="button" class="x go" id="lk-save">Save to Latchkey</button></div>' +
      '<p class="s m" id="lk-status" aria-live="polite"></p>' +
      '<div id="lk-next" hidden><p class="m">Use it in an env file in place of the value:</p>' +
      '<p class="ref"><code id="lk-ref"></code><button type="button" class="x" id="lk-copy">Copy</button></p>' +
      '<p class="m">Then run your project with <code>lk run --env-file .env -- &lt;your command&gt;</code>. If this replaces an older key, revoke the old one on this page.</p></div></div>';
    root.getElementById("what").textContent = label;
    root.getElementById("conf").textContent = { high: "strong match", medium: "possible secret", selected: "you chose it" }[r.confidence] || "likely";
    root.getElementById("prev").textContent = D.preview(r.value);
    var placeSel = root.getElementById("lk-place"), name = root.getElementById("lk-name"), hint = root.getElementById("lk-hint");
    var status = root.getElementById("lk-status"), save = root.getElementById("lk-save");
    name.value = r.name;
    var existing = [];
    function id() { return (placeSel.value ? placeSel.value + "/" : "") + name.value.trim(); }
    function explain() {
      var taken = existing.some(function (e) { return e.id === id(); });
      hint.textContent = taken ? "Replaces the current value; the old one stays in its history." : "Saved as " + id() + ".";
    }
    placeSel.addEventListener("change", explain);
    name.addEventListener("input", explain);
    browser.runtime.sendMessage({ op: "places" }).then(function (res) {
      if (!res || !res.ok) { status.textContent = (res && res.error) || "Couldn't reach Latchkey."; explain(); return; }
      existing = res.items || [];
      res.places.forEach(function (p) { var o = document.createElement("option"); o.value = p; o.textContent = p; placeSel.appendChild(o); });
      // Where this service's key already lives, or a project environment that matches a live or test key.
      var same = existing.filter(function (e) { return r.service && e.service === r.service && e.id.split("/").length === 3; });
      if (same.length === 1) {
        var parts = same[0].id.split("/");
        placeSel.value = parts[0] + "/" + parts[1];
        name.value = parts[2];
      } else if (r.environment) {
        var match = res.places.filter(function (p) { return p.split("/")[1] === r.environment; });
        if (match.length === 1) placeSel.value = match[0];
      }
      explain();
    }).catch(function () { status.textContent = UNREACHABLE; explain(); });
    root.getElementById("lk-no").addEventListener("click", close);
    function close() { h.remove(); if (panelHost === h) panelHost = null; }
    h.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });
    save.addEventListener("click", function () {
      prune();
      if (!live(d)) { retire(d); save.disabled = true; status.textContent = "The value changed or left the page. Scan the current value again before saving."; return; }
      save.disabled = true;
      status.textContent = "Touch ID on your Mac to save it.";
      browser.runtime.sendMessage({ op: "save", id: id(), value: r.value, kind: r.kind, service: r.service }).then(function (res) {
        if (res && res.ok) {
          retire(d);
          status.textContent = "Saved to Latchkey as " + res.id + ".";
          save.hidden = true; placeSel.disabled = true; name.disabled = true; hint.hidden = true;
          root.getElementById("lk-no").textContent = "Done";
          root.getElementById("lk-ref").textContent = res.id.split("/").pop() + "=latchkey://" + res.id;
          root.getElementById("lk-next").hidden = false;
          var pill = pills.get(d.id); if (pill) { pill.remove(); pills.delete(d.id); }
          root.getElementById("lk-copy").addEventListener("click", function (ev) {
            navigator.clipboard.writeText(root.getElementById("lk-ref").textContent).then(function () { ev.target.textContent = "Copied"; }, function () { ev.target.textContent = "Select and copy"; });
          });
        } else {
          status.textContent = (res && res.error) || "Not saved.";
          save.disabled = false;
        }
      }).catch(function () { status.textContent = UNREACHABLE; save.disabled = false; });
    });
    panelHost = h;
    place(h, h._anchor, true, h._fromPill);
    setTimeout(function () { (offeredByPage ? save : name).focus(); place(h, h._anchor, true, h._fromPill); }, 0);
  }

  window.addEventListener("pagehide", function () {
    found.forEach(retire); found = []; byValue.clear();
    if (panelHost) { panelHost.remove(); panelHost = null; }
  });
  scan(document.body || document.documentElement);

  // ---- From the toolbar panel and the context menu
  browser.runtime.onMessage.addListener(function (msg) {
    prune();
    if (msg.op === "detections") {
      return Promise.resolve(found.map(function (d) {
        return { id: d.id, type: d.result.type, service: d.result.service, preview: D.preview(d.result.value), confidence: d.result.confidence };
      }));
    }
    if (msg.op === "open") {
      var d = found.find(function (x) { return x.id === msg.id; });
      if (d) { d.element.scrollIntoView({ block: "center" }); openPanel(d); }
      return Promise.resolve(!!d);
    }
    if (msg.op === "save-selection") {
      var sel = window.getSelection(), text = sel ? sel.toString().trim() : "";
      if (!text) return Promise.resolve(false);
      var anchor = sel.rangeCount ? sel.getRangeAt(0).startContainer.parentElement : document.body;
      // What you chose yourself is saved even if the detector wouldn't have flagged it.
      var r = D.classify(text, contextFor(anchor, true)) ||
        { value: text, type: "Selected text", service: "", name: "API_KEY", kind: text.indexOf("\n") >= 0 ? "key" : "token", confidence: "selected" };
      openPanel({ id: 0, result: r, element: anchor }, anchor);
      return Promise.resolve(true);
    }
    return undefined;
  });
})();
