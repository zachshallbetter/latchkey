// Finds keys and tokens on the page with Latchkey's detector (detector.js) and offers to save them. Confident finds
// get a small "Save to Latchkey" button on the box that holds the key; less certain ones are listed in the toolbar
// panel. It also notes fields that expect a key, token or certificate, by their labels, never their values, and can
// fill one from Latchkey when you choose an item. Values stay in this page until you press Save, and then go only to
// the Latchkey app, which asks you first; a filled value comes from the app only after you approve it, and goes only
// into the field you chose. The toolbar panel sees previews, never values.
(function () {
  "use strict";
  var D = window.LatchkeyDetector;
  if (!D || window.top !== window) return;

  var found = [];            // { id, result, element, elements }
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

  // ---- Where a key is on screen: one box, the frame around its text or the field holding it. The button and the
  // panel are both placed from that box, so they never chase a container or a hidden copy of the key.
  function shownAt(el, r) {
    if (!el || !document.contains(el) || r.width < 4 || r.height < 4) return false;
    var doc = document.documentElement;
    if (r.right + window.scrollX <= 0 || r.bottom + window.scrollY <= 0 || r.left + window.scrollX >= doc.scrollWidth) return false;
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
    // On screen, it must be what you'd hit there: not clipped away or covered.
    var x = r.left + Math.min(r.width / 2, 12), y = r.top + Math.min(r.height / 2, 10);
    if (x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight) return true;
    var hit = document.elementFromPoint(x, y);
    return !!hit && (hit === el || el.contains(hit));
  }
  function textRange(el, value) {
    var head = value.slice(0, 24), w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), n;
    while ((n = w.nextNode())) {
      var i = n.nodeValue.indexOf(head);
      if (i < 0) continue;
      var range = document.createRange();
      range.setStart(n, i);
      // Most keys are one text node; a key split across several (a PEM block with <br>s) ends at this node's end.
      range.setEnd(n, n.nodeValue.indexOf(value, i) === i ? i + value.length : n.nodeValue.length);
      return range;
    }
    return null;
  }
  // The nearest element that visibly frames the text (a bordered box, a code block), if it's close around it.
  function frameFor(p, tr) {
    for (var el = p, i = 0; el && el !== document.body && i < 5; el = el.parentElement, i++) {
      var r = el.getBoundingClientRect();
      if (r.width * r.height > Math.max(tr.width * tr.height * 6, tr.width * tr.height + 60000)) return null;
      var cs = getComputedStyle(el);
      var bordered = parseFloat(cs.borderTopWidth) > 0 && cs.borderTopStyle !== "none";
      var filled = cs.backgroundColor && !/rgba\(0, 0, 0, 0\)|transparent/.test(cs.backgroundColor);
      if (bordered || filled) return el;
    }
    return null;
  }
  function boxFor(el, value) {
    if (el.matches(FIELDS)) {
      var fr = el.getBoundingClientRect();
      return shownAt(el, fr) ? { rect: fr, el: el } : null;
    }
    var range = textRange(el, value);
    if (!range) return null;
    var tr = range.getBoundingClientRect(), p = range.startContainer.parentElement;
    if (!shownAt(p, tr)) return null;
    var frame = frameFor(p, tr);
    var r = frame ? frame.getBoundingClientRect() : { left: tr.left - 4, top: tr.top - 4, right: tr.right + 4, bottom: tr.bottom + 4, width: tr.width + 8, height: tr.height + 8 };
    return { rect: r, el: el };
  }
  // The copy of a key you can see; a page may hold others (a hidden copy for its copy button, a dialog's whole text).
  function boxOf(d) {
    d.elements = (d.elements || [d.element]).filter(function (e) { return document.contains(e); });
    var best = null;
    d.elements.forEach(function (e) {
      var b = boxFor(e, d.result.value);
      if (b && (!best || b.rect.width * b.rect.height < best.rect.width * best.rect.height)) best = b;
    });
    if (best) d.element = best.el;
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
    secretFields = secretFields.filter(function (f) { return !navigated && document.contains(f.el); });
    if (navigated && panelHost) { panelHost.remove(); panelHost = null; }
  }

  function consider(text, el, field) {
    if (!text || text.length < 16 || el.matches("input[type=password], input[type=hidden]") || filled.has(el)) return;
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
      if (r.confidence === "high" && !r.isPublic) showPill(d);
    });
  }

  // ---- Fields that expect a secret, as password managers spot password fields: by label, placeholder, name and
  // autocomplete hint. Their values are never read here (password-type fields included).
  var secretFields = [];     // { el, kind: { type, kind }, label }
  var filled = new WeakSet(); // fields Latchkey filled: what's in them came from Latchkey, so it isn't offered back
  var MAX_FIELDS = 50;
  function noteField(el) {
    if (!D.fieldKind || secretFields.some(function (f) { return f.el === el; })) return;
    var label = labelFor(el);
    var kind = D.fieldKind({ label: label, placeholder: el.getAttribute("placeholder"), name: el.getAttribute("name"), id: el.id, autocomplete: el.getAttribute("autocomplete") });
    if (!kind || secretFields.length >= MAX_FIELDS) return;
    // What you'd call the field: its own label, else its accessible name or placeholder, else its name.
    var own = el.id && document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
    var shown = (own && own.textContent) || (el.closest("label") && el.closest("label").textContent) ||
      el.getAttribute("aria-label") || el.getAttribute("placeholder") || el.getAttribute("name") || "";
    secretFields.push({ el: el, kind: kind, label: shown.replace(/\s+/g, " ").trim().slice(0, 60) });
  }

  function scan(root) {
    if (!root || root.nodeType !== 1 || (panelHost && panelHost.contains(root))) return;
    // Fields, code and cells, where keys are shown on purpose.
    var SHOWN = "code, pre, kbd, samp, td, [data-testid*=key i], [data-testid*=token i], [class*=secret i], [class*=token i], [class*=apikey i]";
    var INPUTS = "input[type=text], input[type=password], input[type=url], input:not([type]), textarea";
    function within(sel) { var all = Array.from(root.querySelectorAll(sel)); if (root.matches(sel)) all.unshift(root); return all; }
    within(FIELDS).forEach(function (el) { consider(el.value, el, true); });
    within(INPUTS).forEach(noteField);
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
    try { browser.runtime.sendMessage({ op: "count", count: found.length }).catch(function () {}); } catch (e) {}
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
  document.addEventListener("focusin", function (e) {
    if (e.target.matches && e.target.matches(FIELDS)) { consider(e.target.value, e.target, true); report(); }
    offerFill(e.target);
  }, true);
  document.addEventListener("input", function (e) { if (e.target.matches && e.target.matches(FIELDS)) later(e.target); }, true);

  // ---- The button on a key's box
  var STYLE =
    ":host{all:initial}" +
    "*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,sans-serif}" +
    "@keyframes lkpop{from{opacity:0;transform:scale(.85)}}" +
    ".pill{display:inline-flex;align-items:center;gap:6px;padding:3px 10px 3px 7px;height:24px;border-radius:999px;border:0;cursor:pointer;" +
    "background:#0a63d1;color:#fff;font:600 12px/1 -apple-system,sans-serif;box-shadow:0 2px 8px rgba(10,99,209,.35);animation:lkpop .14s ease-out}" +
    ".pill.icon{width:24px;padding:0;justify-content:center}.pill.icon span{display:none}" +
    ".pill:hover{filter:brightness(1.08)}.pill:focus-visible{outline:2px solid #fff;outline-offset:-4px}" +
    ".pill svg{width:12px;height:12px;fill:#fff;flex:none}" +
    "@keyframes lkin{from{opacity:0;transform:translateY(var(--lk-dy,-6px)) scale(.97)}}" +
    "@media (prefers-reduced-motion:reduce){.b,.pill{animation:none!important}}" +
    ".b{animation:lkin .16s ease-out;font:13px/1.45 -apple-system,sans-serif;width:340px;padding:14px;border-radius:12px;background:#fff;color:#12161c;" +
    "border:1px solid #dde2e9;box-shadow:0 12px 32px rgba(16,24,40,.22)}" +
    "@media (prefers-color-scheme:dark){.b{background:#1c2128;color:#e8ecf1;border-color:#2f3640}.m{color:#a3adb9!important}input,select{background:#13181e!important;color:inherit!important;border-color:#2f3640!important}}" +
    "b.t{display:block;font-size:14px;margin-bottom:2px}.m{color:#5a6472;margin:0 0 10px}code{font:12px ui-monospace,Menlo,monospace}" +
    "label{display:block;font-weight:600;margin:8px 0 3px}select,input{width:100%;padding:6px 8px;border:1px solid #c9d0d9;border-radius:7px;font:13px -apple-system,sans-serif;background:#fff}" +
    ".r{display:flex;gap:8px;justify-content:flex-end;margin-top:12px}button.x{font:600 13px -apple-system,sans-serif;padding:6px 12px;border-radius:7px;border:1px solid #c9d0d9;background:transparent;color:inherit;cursor:pointer}" +
    "button.go{background:#0a63d1;border-color:#0a63d1;color:#fff}button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid #0a63d1;outline-offset:1px}" +
    ".s{margin:10px 0 0;min-height:1em}.hint{margin:4px 0 0;font-size:12px}.conf{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:5px;font-size:11px;font-weight:600;background:rgba(127,127,127,.18)}" +
    ".ref{display:flex;align-items:center;gap:8px;margin:0 0 8px;padding:6px 8px;border-radius:7px;background:rgba(127,127,127,.14)}.ref code{flex:1;overflow-wrap:anywhere}";
  var MARK = '<svg viewBox="0 0 523 544" aria-hidden="true"><path d="M405.4,40.3C449,46.4 480.9,82.9 482.9,125.3C496.2,127.9 509.8,130.9 523,133.8C531.6,17.7 373.8,-46.7 298.2,40.2C314,43.4 328.6,48.5 342,55.1C359.9,42.9 382.2,37 405.4,40.3Z"/><path d="M361.9,266.2C311.8,255 272.3,217.2 258.9,167.4C252.9,147.6 271.1,126.5 291.5,129.6C328.5,139.7 320.5,198.8 377,208.8C389.9,212.6 402.2,211 417.2,206.1C410.4,-54.8 29.4,32.8 123.4,276C117,295.9 96.3,309 89.1,328.6C83.1,359.5 85.6,354.9 60.5,368.5C47.7,378.5 65.4,406.1 46.1,409.2C26.6,412.3 0.8,460.9 0.2,465.1C-0.5,470.3 0.1,540.1 6,543.6C18,546.5 68.3,535.6 92.4,528.8C113.5,508.9 201.2,389.6 225.6,360.7C231,352.4 241.2,356.8 249.2,356.9C325.7,363.7 378.1,323.6 402.3,270.2C388.9,270.9 375.1,269.7 362,266.3Z"/><path d="M523.3,129.8C520.8,163.7 513,186.7 498.6,207.1L466.4,183.8C478.4,167.7 483.9,145.3 482.7,121.2Z"/><path d="M498.6,207.1C513.7,185.7 482.4,162.3 466.4,183.8C450.6,205.1 412.1,224.7 383,220.2C340.2,215.9 319.9,180.3 305.5,152.2C299.5,142.7 293.1,137.2 283.1,139.9C272.1,142.5 265.6,153.8 268.6,164.7C280.7,209.9 316.6,245.8 364.3,256.4C413.8,269.3 469.3,248.7 498.6,206.9Z"/></svg>';

  function host(z) {
    var h = document.createElement("div");
    // Hidden until it has a place, so it never appears somewhere and then jumps.
    h.style.cssText = "position:fixed;z-index:" + z + ";top:0;left:0;visibility:hidden;";
    document.documentElement.appendChild(h);
    return h;
  }
  function same(a, b) { return a && b && Math.abs(a.left - b.left) < 1 && Math.abs(a.top - b.top) < 1 && Math.abs(a.width - b.width) < 1 && Math.abs(a.height - b.height) < 1; }

  // The button sits on the box: inside a one-line field at its right end (icon only, as password managers do), or on
  // the top edge of a taller box at its right, like a tab. It appears once the box has stopped moving (dialogs
  // animate in), and follows it from then on.
  function placePill(h, d) {
    var b = boxOf(d), r = b && b.rect;
    if (!r || r.bottom < 0 || r.top > window.innerHeight) { h.style.display = "none"; h._last = null; return; }
    var button = h._button, oneLine = r.height < 48;
    button.classList.toggle("icon", oneLine);
    h.style.display = "";
    if (h.style.visibility === "hidden" && !same(h._last, r)) { h._last = { left: r.left, top: r.top, width: r.width, height: r.height }; return; }
    h._last = { left: r.left, top: r.top, width: r.width, height: r.height };
    var w = h.offsetWidth, ht = h.offsetHeight;
    var left = oneLine ? r.right - w - 6 : r.right - w - 12;
    var top = oneLine ? r.top + (r.height - ht) / 2 : r.top - ht / 2;
    h.style.left = Math.round(Math.min(window.innerWidth - w - 4, Math.max(4, left))) + "px";
    h.style.top = Math.round(Math.max(4, top)) + "px";
    h.style.visibility = "visible";
  }

  // The panel opens from the button, beside the box rather than over the key: below it, else above, else to a side.
  function placePanel(h) {
    var d = h._d, b = d && d.id ? boxOf(d) : null, r = b && b.rect, pad = 8;
    var w = h.offsetWidth || 340, ht = h.offsetHeight || 280, vw = window.innerWidth, vh = window.innerHeight;
    if (!r && h._anchor && document.contains(h._anchor)) r = h._anchor.getBoundingClientRect();
    if (!r || (!r.width && !r.height)) {   // nothing on screen to sit beside: the bottom-right corner
      h.style.left = Math.max(pad, vw - w - 16) + "px"; h.style.top = Math.max(pad, vh - ht - 16) + "px";
      h.style.visibility = "visible"; return;
    }
    var tab = pills.has(d && d.id) && r.height >= 48 ? 12 : 0;   // the button's half above the top edge
    var left = Math.min(vw - w - pad, Math.max(pad, r.right - w)), top, origin, dy;
    if (r.bottom + pad + ht <= vh - pad) { top = r.bottom + pad; origin = "top right"; dy = "-6px"; }
    else if (r.top - tab - pad - ht >= pad) { top = r.top - tab - pad - ht; origin = "bottom right"; dy = "6px"; }
    else {
      top = Math.min(vh - ht - pad, Math.max(pad, r.top)); dy = "0px";
      if (r.right + pad + w <= vw - pad) { left = r.right + pad; origin = "top left"; }
      else { left = Math.max(pad, r.left - pad - w); origin = "top right"; }
    }
    h.style.left = Math.round(left) + "px"; h.style.top = Math.round(top) + "px";
    h._panel.style.transformOrigin = origin; h._panel.style.setProperty("--lk-dy", dy);
    h.style.visibility = "visible";
  }

  function showPill(d) {
    if (pills.has(d.id)) return;
    var h = host(2147483646);
    var root = h.attachShadow({ mode: "closed" });
    root.innerHTML = "<style>" + STYLE + "</style><button class='pill' type='button'>" + MARK + "<span>Save to Latchkey</span></button>";
    h._button = root.querySelector("button");
    h._button.setAttribute("aria-label", "Save this " + (d.result.service || "secret") + " to Latchkey");
    h._button.title = "Save to Latchkey";
    h._button.addEventListener("click", function () { openPanel(d); });
    pills.set(d.id, h);
    placePill(h, d);
  }
  function reposition() {
    prune();
    pills.forEach(function (h, id) {
      var d = found.find(function (x) { return x.id === id; });
      if (!d) { h.remove(); pills.delete(id); return; }
      placePill(h, d);
    });
    offer();
    if (panelHost) placePanel(panelHost);
  }
  // A key a page says it shows only once (a "your new key" dialog) gets the save panel without a click, once its
  // button has settled on it. Saving still takes your press and Touch ID. Once per key, never over an open panel.
  var offered = new Set();
  function offer() {
    if (panelHost) return;
    for (var i = 0; i < found.length; i++) {
      var d = found[i], pill = pills.get(d.id);
      if (d.result.confidence !== "high" || !d.result.shownOnce || offered.has(d.result.value)) continue;
      if (!pill || pill.style.visibility !== "visible") continue;
      offered.add(d.result.value);
      openPanel(d, null, true);
      return;
    }
  }
  var queued = false;
  function soon() { if (!queued) { queued = true; requestAnimationFrame(function () { queued = false; reposition(); }); } }
  window.addEventListener("scroll", soon, true);
  window.addEventListener("resize", soon);
  setInterval(function () { if (pills.size || panelHost) reposition(); }, 200);   // dialogs move and close without scrolling

  // ---- Saving
  function openPanel(d, anchor, offeredByPage) {
    prune();
    if (!live(d)) return;
    if (panelHost) panelHost.remove();
    var r = d.result;
    var h = host(2147483647);
    h._d = d; h._anchor = anchor || d.element;
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
    h._panel = root.querySelector(".b");
    root.getElementById("what").textContent = label;
    root.getElementById("conf").textContent = r.isPublic ? "not secret" : { high: "strong match", medium: "possible secret", selected: "you chose it" }[r.confidence] || "likely";
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
      placePanel(h);
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
        placePanel(h);
      }).catch(function () { status.textContent = UNREACHABLE; save.disabled = false; });
    });
    panelHost = h;
    placePanel(h);
    setTimeout(function () { (offeredByPage ? save : name).focus(); placePanel(h); }, 0);
  }

  // ---- Filling a field from Latchkey. Clicking into a field that expects a key shows a Latchkey badge in it; the
  // badge lists the items the app allows on this site (names only), and choosing one asks for Touch ID. The value
  // comes back only then, and goes straight into that field.
  var fillBadge = null;
  function fieldOf(el) { return secretFields.find(function (f) { return f.el === el; }); }
  function empty(el) { return el.type === "password" ? true : !el.value; }   // never reads a password field
  function hideFillBadge() { if (fillBadge) { fillBadge.remove(); fillBadge = null; } }
  function placeFillBadge() {
    if (!fillBadge) return;
    var el = fillBadge._field.el, r = el.getBoundingClientRect();
    if (!document.contains(el) || !r.width) { hideFillBadge(); return; }
    var w = fillBadge.offsetWidth, ht = fillBadge.offsetHeight;
    fillBadge.style.left = Math.round(r.right - w - 6) + "px";
    fillBadge.style.top = Math.round(r.height < 48 ? r.top + (r.height - ht) / 2 : r.top + 6) + "px";
    fillBadge.style.visibility = "visible";
  }
  function showFillBadge(f) {
    if (fillBadge && fillBadge._field === f) return;
    hideFillBadge();
    var h = host(2147483646);
    var root = h.attachShadow({ mode: "closed" });
    root.innerHTML = "<style>" + STYLE + "</style><button class='pill icon' type='button'>" + MARK + "<span>Fill from Latchkey</span></button>";
    var b = root.querySelector("button");
    b.setAttribute("aria-label", "Fill this " + f.kind.type.toLowerCase() + " from Latchkey");
    b.title = "Fill from Latchkey";
    b.addEventListener("mousedown", function (e) { e.preventDefault(); });   // keep the field focused
    b.addEventListener("click", function () { openFillPanel(f); });
    h._field = f; fillBadge = h;
    placeFillBadge();
  }
  function offerFill(el) {
    if (!el || !el.matches || !el.matches("input, textarea")) return;
    noteField(el);
    var f = fieldOf(el);
    if (f && !filled.has(el) && empty(el) && !(pills.size && found.some(function (d) { return d.element === el; }))) showFillBadge(f);
  }
  document.addEventListener("focusout", function (e) {
    if (!fillBadge || e.target !== fillBadge._field.el) return;
    setTimeout(function () { if (fillBadge && document.activeElement !== fillBadge._field.el && !(panelHost && panelHost._field)) hideFillBadge(); }, 150);
  }, true);
  window.addEventListener("scroll", function () { if (fillBadge) requestAnimationFrame(placeFillBadge); }, true);
  window.addEventListener("resize", placeFillBadge);

  function setValue(el, v) {
    // Through the element's own setter, then the events a typed value fires, so the page's framework sees it.
    var proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, v);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // Items most like the field first: the same kind, then words its label shares with the item's name.
  function rank(items, f) {
    var words = (f.label || "").toLowerCase().split(/[^a-z0-9]+/).filter(function (w) { return w.length > 2; });
    function score(i) {
      var name = i.id.split("/").pop().toLowerCase(), s = i.kind === f.kind.kind ? 2 : 0;
      words.forEach(function (w) { if (name.indexOf(w) >= 0 || (i.service || "").toLowerCase() === w) s += 1; });
      return s;
    }
    return items.map(function (i) { return { i: i, s: score(i) }; }).sort(function (a, b) { return b.s - a.s || a.i.id.localeCompare(b.i.id); }).map(function (x) { return x.i; });
  }

  function openFillPanel(f) {
    if (panelHost) panelHost.remove();
    var h = host(2147483647);
    h._d = null; h._anchor = f.el; h._field = f;
    var root = h.attachShadow({ mode: "closed" });
    root.innerHTML = "<style>" + STYLE +
      ".list{max-height:220px;overflow:auto;margin:8px 0 0;padding:0;list-style:none}.list button{width:100%;text-align:left;display:block;padding:6px 8px;margin:0 0 4px;" +
      "border:1px solid rgba(127,127,127,.3);border-radius:7px;background:transparent;color:inherit;font:13px -apple-system,sans-serif;cursor:pointer}" +
      ".list button:hover{background:rgba(127,127,127,.12)}.list small{display:block;color:#8a94a2;font-size:11px}</style>" +
      '<div class="b" role="dialog" aria-label="Fill from Latchkey">' +
      '<b class="t">Fill from Latchkey</b><p class="m" id="what"></p>' +
      '<input id="lk-q" placeholder="Search items" autocomplete="off" spellcheck="false" aria-label="Search items">' +
      '<ul class="list" id="lk-items"></ul>' +
      '<p class="s m" id="lk-status" aria-live="polite"></p>' +
      '<div class="r"><button type="button" class="x" id="lk-no">Not now</button></div></div>';
    h._panel = root.querySelector(".b");
    var status = root.getElementById("lk-status"), list = root.getElementById("lk-items"), q = root.getElementById("lk-q");
    root.getElementById("what").textContent = f.kind.type + (f.label ? " · " + f.label : "");
    function close() { h.remove(); if (panelHost === h) panelHost = null; }
    root.getElementById("lk-no").addEventListener("click", close);
    h.addEventListener("keydown", function (e) { if (e.key === "Escape") { close(); f.el.focus(); } });
    var items = [];
    function draw() {
      list.textContent = "";
      var term = q.value.trim().toLowerCase();
      items.filter(function (i) { return !term || (i.id + " " + i.service).toLowerCase().indexOf(term) >= 0; }).slice(0, 50).forEach(function (i) {
        var li = document.createElement("li"), b = document.createElement("button"), small = document.createElement("small");
        b.type = "button"; b.textContent = i.id.split("/").pop();
        small.textContent = (i.id.indexOf("/") > 0 ? i.id.split("/").slice(0, 2).join("/") : "shared") + (i.service ? " · " + i.service : "");
        b.append(small); li.append(b); list.append(li);
        b.addEventListener("click", function () { fill(i, b); });
      });
      placePanel(h);
    }
    function fill(i, button) {
      Array.from(list.querySelectorAll("button")).forEach(function (x) { x.disabled = true; });
      status.textContent = "Touch ID on your Mac to fill " + i.id.split("/").pop() + ".";
      browser.runtime.sendMessage({ op: "fill", id: i.id }).then(function (res) {
        if (res && res.ok && typeof res.value === "string" && document.contains(f.el)) {
          filled.add(f.el);
          setValue(f.el, res.value);
          res.value = null;
          close(); hideFillBadge(); f.el.focus();
        } else {
          status.textContent = (res && res.error) || "Not filled.";
          Array.from(list.querySelectorAll("button")).forEach(function (x) { x.disabled = false; });
        }
      }).catch(function () { status.textContent = UNREACHABLE; });
    }
    q.addEventListener("input", draw);
    browser.runtime.sendMessage({ op: "fillable" }).then(function (res) {
      if (!res || !res.ok) { status.textContent = (res && res.error) || UNREACHABLE; placePanel(h); return; }
      items = rank(res.items || [], f);
      if (!items.length) status.textContent = "Nothing in Latchkey can be filled on " + (res.host || "this site") + ". Latchkey fills an item only on its service's own site and where deployments keep their environment variables.";
      draw();
    }).catch(function () { status.textContent = UNREACHABLE; placePanel(h); });
    panelHost = h;
    placePanel(h);
    setTimeout(function () { q.focus(); placePanel(h); }, 0);
  }

  window.addEventListener("pagehide", function () {
    found.forEach(retire); found = []; byValue.clear(); secretFields = []; hideFillBadge();
    if (panelHost) { panelHost.remove(); panelHost = null; }
  });
  scan(document.body || document.documentElement);

  // ---- From the toolbar panel and the context menu
  browser.runtime.onMessage.addListener(function (msg) {
    prune();
    if (msg.op === "detections") {
      return Promise.resolve(found.map(function (d) {
        return { id: d.id, type: d.result.type, service: d.result.service, preview: D.preview(d.result.value), confidence: d.result.confidence, isPublic: !!d.result.isPublic };
      }));
    }
    if (msg.op === "fields") {
      // What each field expects and its label: page text, never a value.
      return Promise.resolve(secretFields.map(function (f) { return { type: f.kind.type, label: f.label }; }));
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
