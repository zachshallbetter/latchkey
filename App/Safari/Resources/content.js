// On a service's key pages, watches for a newly shown API key and offers to save it to Latchkey. The value only
// goes to Latchkey when you press Save, and the app asks you to approve it. Masked keys (sk_live_…a1b2) aren't
// matched; only a key shown in full, as services do once, right after you create it.
(function () {
  var KINDS = [
    { re: /\bsk_(?:live|test)_[A-Za-z0-9]{24,}\b/, service: "Stripe", name: "STRIPE_SECRET_KEY" },
    { re: /\brk_(?:live|test)_[A-Za-z0-9]{24,}\b/, service: "Stripe", name: "STRIPE_RESTRICTED_KEY" },
    { re: /\bsk-ant-[A-Za-z0-9_-]{20,}\b/, service: "Anthropic", name: "ANTHROPIC_API_KEY" },
    { re: /\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}\b/, service: "OpenAI", name: "OPENAI_API_KEY" },
    { re: /\b(?:github_pat_[A-Za-z0-9_]{50,}|ghp_[A-Za-z0-9]{36})\b/, service: "GitHub", name: "GITHUB_TOKEN" }
  ];
  var offered = new Set();
  var bar = null;

  function find(text) {
    if (!text || text.length < 20) return null;
    for (var i = 0; i < KINDS.length; i++) {
      var m = text.match(KINDS[i].re);
      if (m) return { value: m[0], kind: KINDS[i] };
    }
    return null;
  }

  function scan() {
    if (bar) return;
    var fields = document.querySelectorAll("input, textarea, code, pre, [data-testid], [class*='key'], [class*='secret'], [class*='token']");
    for (var i = 0; i < fields.length; i++) {
      var el = fields[i];
      var text = el.value !== undefined && (el.tagName === "INPUT" || el.tagName === "TEXTAREA") ? el.value : el.textContent;
      var hit = find(text);
      if (hit && !offered.has(hit.value)) { offered.add(hit.value); offer(hit); return; }
    }
  }

  var queued = false;
  function soon() { if (!queued) { queued = true; setTimeout(function () { queued = false; scan(); }, 400); } }
  new MutationObserver(soon).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
  // Fields filled in by script don't always change the page's structure.
  setInterval(scan, 1500);
  scan();

  function preview(v) { return v.slice(0, v.indexOf("_", 3) > 0 && v.indexOf("_", 3) < 12 ? v.indexOf("_", 3) + 1 : 8) + "…" + v.slice(-4); }

  function offer(hit) {
    var host = document.createElement("div");
    host.style.cssText = "position:fixed;right:16px;bottom:16px;z-index:2147483647;";
    var root = host.attachShadow({ mode: "closed" });
    root.innerHTML =
      "<style>" +
      ":host{all:initial}" +
      ".b{font:13px/1.45 -apple-system,BlinkMacSystemFont,sans-serif;width:340px;padding:14px;border-radius:12px;background:#fff;color:#12161c;" +
      "border:1px solid #dde2e9;box-shadow:0 12px 32px rgba(16,24,40,.18)}" +
      "@media (prefers-color-scheme:dark){.b{background:#1c2128;color:#e8ecf1;border-color:#2f3640}.m{color:#a3adb9!important}input,select{background:#13181e!important;color:inherit!important;border-color:#2f3640!important}}" +
      "b{display:block;font-size:14px;margin-bottom:2px}.m{color:#5a6472;margin:0 0 10px}code{font:12px ui-monospace,Menlo,monospace}" +
      "label{display:block;font-weight:600;margin:8px 0 3px}select,input{width:100%;box-sizing:border-box;padding:6px 8px;border:1px solid #c9d0d9;border-radius:7px;font:13px -apple-system,sans-serif;background:#fff}" +
      ".r{display:flex;gap:8px;justify-content:flex-end;margin-top:12px}button{font:600 13px -apple-system,sans-serif;padding:6px 12px;border-radius:7px;border:1px solid #c9d0d9;background:transparent;color:inherit;cursor:pointer}" +
      "button.go{background:#0a63d1;border-color:#0a63d1;color:#fff}button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid #0a63d1;outline-offset:1px}" +
      ".s{margin:10px 0 0;min-height:1em}.hint{margin:4px 0 0;font-size:12px}" +
      ".ref{display:flex;align-items:center;gap:8px;margin:0 0 8px;padding:6px 8px;border-radius:7px;background:rgba(127,127,127,.14)}.ref code{flex:1;overflow-wrap:anywhere}" +
      "</style>" +
      '<div class="b" role="region" aria-label="Latchkey">' +
      "<b>Save this " + hit.kind.service + " key to Latchkey?</b>" +
      '<p class="m">Found on this page: <code></code></p>' +
      '<label for="lk-place">Where</label><select id="lk-place"><option value="">Shared (every project)</option></select>' +
      '<label for="lk-name">Name</label><input id="lk-name" autocomplete="off" spellcheck="false">' +
      '<p class="m hint" id="lk-hint"></p>' +
      '<div class="r"><button type="button" id="lk-no">Not now</button><button type="button" class="go" id="lk-save">Save to Latchkey</button></div>' +
      '<p class="s m" id="lk-status" aria-live="polite"></p>' +
      '<div id="lk-next" hidden><p class="m">Use it in an env file in place of the value:</p>' +
      '<p class="ref"><code id="lk-ref"></code><button type="button" id="lk-copy">Copy</button></p>' +
      '<p class="m">Then run your project with <code>lk run --env-file .env -- &lt;your command&gt;</code>. If this key replaces an older one, revoke the old one on this page.</p></div></div>';
    root.querySelector("code").textContent = preview(hit.value);
    var place = root.getElementById("lk-place"), name = root.getElementById("lk-name"), hint = root.getElementById("lk-hint");
    var status = root.getElementById("lk-status"), save = root.getElementById("lk-save");
    name.value = hit.kind.name;
    var existing = [];

    function id() { return (place.value ? place.value + "/" : "") + name.value.trim(); }
    function explain() {
      var taken = existing.some(function (e) { return e.id === id(); });
      hint.textContent = taken ? "Replaces the current value; the old one stays in its history." : "Saved as " + id() + ".";
    }
    place.addEventListener("change", explain);
    name.addEventListener("input", explain);

    browser.runtime.sendMessage({ op: "places" }).then(function (r) {
      if (!r || !r.ok) { status.textContent = (r && r.error) || "Couldn't reach Latchkey."; explain(); return; }
      existing = r.items || [];
      r.places.forEach(function (p) { var o = document.createElement("option"); o.value = p; o.textContent = p; place.appendChild(o); });
      // Put it where the same service's key already lives, if there's one place for it.
      var same = existing.filter(function (e) { return e.service === hit.kind.service && e.id.split("/").length === 3; });
      if (same.length === 1) {
        var parts = same[0].id.split("/");
        place.value = parts[0] + "/" + parts[1];
        name.value = parts[2];
      }
      explain();
    });

    function close() { host.remove(); bar = null; }
    root.getElementById("lk-no").addEventListener("click", close);
    save.addEventListener("click", function () {
      save.disabled = true;
      status.textContent = "Touch ID on your Mac to save it.";
      browser.runtime.sendMessage({ op: "save", id: id(), value: hit.value, kind: "token", service: hit.kind.service }).then(function (r) {
        if (r && r.ok) {
          status.textContent = "Saved to Latchkey as " + r.id + ".";
          save.hidden = true;
          place.disabled = true; name.disabled = true; hint.hidden = true;
          root.getElementById("lk-no").textContent = "Done";
          var ref = "latchkey://" + r.id;
          root.getElementById("lk-ref").textContent = r.id.split("/").pop() + "=" + ref;
          root.getElementById("lk-next").hidden = false;
          root.getElementById("lk-copy").addEventListener("click", function (ev) {
            var line = root.getElementById("lk-ref").textContent;
            navigator.clipboard.writeText(line).then(function () { ev.target.textContent = "Copied"; }, function () { ev.target.textContent = "Select and copy"; });
          });
        } else {
          status.textContent = (r && r.error) || "Not saved.";
          save.disabled = false;
        }
      });
    });
    bar = host;
    document.documentElement.appendChild(host);
  }
})();
