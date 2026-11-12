// A working copy of the Latchkey window with example data: the sidebar's filters and counts, projects and
// environments that open and close, an item's detail, Activity and Grants. What the visitor does in the approval
// scene on the home page arrives here as lk:activity and lk:grant events; elsewhere it starts from the example
// data. Revealing a value or changing a setting asks for Touch ID, as the app does.
(function () {
  var root = document.getElementById("appwin");
  if (!root) return;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  function ago(d) {
    var s = Math.round((Date.now() - d) / 1000);
    if (s < 60) return "just now";
    if (s < 3600) return Math.round(s / 60) + " min ago";
    return Math.round(s / 3600) + " hours ago";
  }

  // ---- Example data. Values are made up and say so.
  var USED = ["~/Projects/shop/.env.local"];
  var items = [
    { id: "shop/development/DATABASE_URL", kind: "password", service: "Neon", safe: false, note: "imported from .env.local", used: USED,
      sample: "postgres://app:example-only@db.neon.tech/shop" },
    { id: "shop/development/STRIPE_KEY", kind: "token", service: "Stripe", safe: false, note: "imported from .env.local", used: USED,
      sample: "sk_test_example-only" },
    { id: "shop/development/PGHOST", kind: "value", service: "Neon", safe: true, note: "imported from .env.local", used: USED,
      sample: "ep-example.us-east-2.aws.neon.tech" },
    { id: "shop/vercel.preview/DATABASE_URL", kind: "password", service: "Neon", safe: false, note: "", used: [],
      sample: "postgres://preview:example-only@db.neon.tech/shop", remote: "Vercel shop · preview" },
    { id: "shop/production/DATABASE_URL", kind: "password", service: "Neon", safe: false, note: "", used: [],
      sample: "postgres://prod:example-only@db.neon.tech/shop", remote: "Vercel shop · production",
      history: [{ when: "Oct 28", why: "replaced by zsh › Terminal" }] },
    { id: "shop/production/STRIPE_KEY", kind: "token", service: "Stripe", safe: false, note: "", used: [],
      sample: "sk_live_example-only", remote: "Vercel shop · production" },
    { id: "OPENAI_API_KEY", kind: "token", service: "OpenAI", safe: false, note: "shared by every project", used: [],
      sample: "sk-proj-example-only" }
  ];
  var KINDS = { token: ["Tokens", "Token", "key"], password: ["Passwords", "Password", "lock"], key: ["Key files", "Key file", "file"], value: ["Plain values", "Plain value", "tag"] };
  var PLACES = { development: "Local", "vercel.preview": "Vercel", production: "Vercel" };
  var activity = [
    { op: "import", names: ["shop/development/DATABASE_URL", "shop/development/STRIPE_KEY", "shop/development/PGHOST"], decision: "approved",
      chain: "zsh › Terminal", cwd: "~/Projects/shop", time: new Date(Date.now() - 2 * 3600e3) }
  ];
  var grants = [];
  var state = { filter: "all", selected: items[0].id, open: { shop: true, "shop/development": true }, revealed: {} };

  function parts(id) { var p = id.split("/"); return p.length === 3 ? { project: p[0], env: p[1], name: p[2] } : { project: "", env: "", name: id }; }
  function matches(f, i) {
    if (f === "all") return true;
    if (f === "safe") return i.safe;
    if (f === "ask") return !i.safe;
    if (f.indexOf("kind:") === 0) return i.kind === f.slice(5);
    if (f.indexOf("project:") === 0) return parts(i.id).project === f.slice(8);
    if (f.indexOf("service:") === 0) return i.service === f.slice(8);
    return false;
  }
  function count(f) { return items.filter(function (i) { return matches(f, i); }).length; }
  var ICON = {
    key: '<path d="M8.5 1.5a3.5 3.5 0 0 0-3.3 4.6L1.5 9.8V12h2.2v-1.2h1.2V9.6h1.2l1-1a3.5 3.5 0 1 0 1.4-7.1zm1 2.2a.9.9 0 1 1 0 1.8.9.9 0 0 1 0-1.8z"/>',
    lock: '<path d="M4 6V4.5a3 3 0 0 1 6 0V6h.5A1.5 1.5 0 0 1 12 7.5v4A1.5 1.5 0 0 1 10.5 13h-7A1.5 1.5 0 0 1 2 11.5v-4A1.5 1.5 0 0 1 3.5 6zm1.5 0h3V4.5a1.5 1.5 0 0 0-3 0z"/>',
    file: '<path d="M3 1.5h5l3 3v8a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1v-10a1 1 0 0 1 1-1zm4.5 0v3h3"/>',
    tag: '<path d="M1.5 2.5v4l6 6 5-5-6-6h-4a1 1 0 0 0-1 1zm2.5.5a1 1 0 1 1 0 2 1 1 0 0 1 0-2z"/>'
  };
  function kindIcon(k) { return '<span class="ki ki-' + k + '"><svg viewBox="0 0 14 14" aria-hidden="true">' + ICON[KINDS[k][2]] + "</svg></span>"; }

  // ---- Touch ID inside the window, for reveals and changes made in the app.
  function touchID(text) {
    var sheet = root.querySelector(".touch");
    sheet.querySelector(".touch-text").textContent = text;
    return new Promise(function (resolve) {
      var done = false, timer;
      function end(ok) {
        if (done) return; done = true; clearTimeout(timer);
        sheet.classList.remove("reading");
        if (!ok) { sheet.hidden = true; resolve(false); return; }
        sheet.classList.add("ok");
        setTimeout(function () { sheet.hidden = true; sheet.classList.remove("ok"); resolve(true); }, reduce ? 250 : 450);
      }
      sheet.hidden = false; sheet.classList.add("reading");
      sheet.querySelector('[data-t="pw"]').onclick = function () { end(true); };
      sheet.querySelector('[data-t="deny"]').onclick = function () { end(false); };
      sheet.querySelector('[data-t="deny"]').focus({ preventScroll: true });
      timer = setTimeout(function () { end(true); }, reduce ? 900 : 1600);
    });
  }
  function log(op, names, decision) {
    activity.unshift({ op: op, names: names, decision: decision, chain: "the Latchkey app", cwd: "", time: new Date() });
  }

  // ---- Rendering
  function side() {
    function tile(f, label, n, cls) {
      return '<button type="button" class="tile ' + cls + '" data-f="' + f + '" aria-pressed="' + (state.filter === f) + '"><span class="tn">' + n + "</span>" + label + "</button>";
    }
    function row(f, label, n, icon) {
      return '<li><button type="button" data-f="' + f + '" aria-pressed="' + (state.filter === f) + '">' + icon + "<span>" + esc(label) + "</span><em>" + n + "</em></button></li>";
    }
    var services = Array.from(new Set(items.map(function (i) { return i.service; }))).sort();
    return '<div class="side">' +
      '<div class="tiles">' + tile("all", "All", items.length, "t-all") + tile("safe", "No Approval", count("safe"), "t-safe") +
      tile("ask", "Ask First", count("ask"), "t-ask") + tile("activity", "Activity", activity.length, "t-act") + "</div>" +
      "<p class=\"sh\">Kinds</p><ul>" + Object.keys(KINDS).map(function (k) { return row("kind:" + k, KINDS[k][0], count("kind:" + k), kindIcon(k)); }).join("") + "</ul>" +
      '<p class="sh">Projects</p><ul>' + row("project:shop", "shop", count("project:shop"), '<span class="ki ki-proj"></span>') + "</ul>" +
      '<p class="sh">Services</p><ul>' + services.map(function (sv) { return row("service:" + sv, sv, count("service:" + sv), '<span class="ki ki-svc"></span>'); }).join("") + "</ul>" +
      '<p class="sh">Access</p><ul>' + row("grants", "Grants", grants.length, '<span class="ki ki-grant"></span>') +
      row("deleted", "Recently Deleted", 0, '<span class="ki ki-del"></span>') + "</ul>" +
      '<p class="sync"><b>iCloud Keychain</b>iCloud Keychain storage; delivery is not verified.</p></div>';
  }

  function list() {
    var f = state.filter;
    if (f === "activity") return '<div class="list wide"><p class="lt">Activity <small>' + activity.length + " entries</small></p>" + activity.map(entry).join("") + "</div>";
    if (f === "grants") {
      return '<div class="list wide"><p class="lt">Grants <small>' + grants.length + " in effect</small></p>" +
        (grants.length ? grants.map(function (g) {
          return '<div class="grantrow"><div><b>' + esc(g.folder) + "</b><span>" + esc(g.names.map(function (n) { return parts(n).name; }).join(", ")) +
            "</span><span>" + esc(g.limits.charAt(0).toUpperCase() + g.limits.slice(1)) + ", at most 1 day</span></div>" +
            '<button type="button" class="pill" data-revoke="' + g.id + '">Revoke</button></div>';
        }).join("") : '<p class="empty">No grants in effect. Choose “Allow” in the approval panel above to make one.</p>') + "</div>";
    }
    if (f === "deleted") return '<div class="list wide"><p class="lt">Recently Deleted</p><p class="empty">Nothing deleted in the last 30 days.</p></div>';
    var shown = items.filter(function (i) { return matches(f, i); });
    var html = '<div class="list"><p class="lt">' + esc(title(f)) + " <small>" + shown.length + " items</small></p>";
    var projects = {};
    shown.forEach(function (i) { var p = parts(i.id); (projects[p.project] = projects[p.project] || {})[p.env] = (projects[p.project][p.env] || []).concat(i); });
    Object.keys(projects).sort(function (a, b) { return a === "" ? 1 : b === "" ? -1 : a.localeCompare(b); }).forEach(function (p) {
      var envs = projects[p], n = Object.values(envs).reduce(function (a, l) { return a + l.length; }, 0);
      var open = !!state.open[p || "shared"];
      html += '<button type="button" class="grp" data-open="' + (p || "shared") + '" aria-expanded="' + open + '"><span class="chev"></span>' +
        '<span class="ki ' + (p ? "ki-proj" : "ki-shared") + '"></span><b>' + (p ? esc(p) : "Shared") + "</b><em>" + n + "</em>" +
        (p ? Object.keys(envs).map(function (e) { return '<span class="env env-' + e.split(".").pop() + '">' + esc(e) + "</span>"; }).join("") : "") + "</button>";
      if (!open) return;
      Object.keys(envs).forEach(function (e) {
        var key = p ? p + "/" + e : "shared";
        var rows = envs[e].map(itemRow).join("");
        if (!p) { html += rows; return; }
        var eo = !!state.open[key];
        html += '<button type="button" class="grp sub" data-open="' + key + '" aria-expanded="' + eo + '"><span class="chev"></span><span class="env env-' + e.split(".").pop() + '">' + esc(e) + "</span><em>" + envs[e].length + '</em><span class="place">' + (PLACES[e] || "") + "</span></button>";
        if (eo) html += rows;
      });
    });
    return html + "</div>";
  }
  function title(f) {
    return { all: "All", safe: "No Approval", ask: "Ask First" }[f] || (f.indexOf("kind:") === 0 ? KINDS[f.slice(5)][0] : f.split(":")[1]);
  }
  function itemRow(i) {
    var p = parts(i.id);
    return '<button type="button" class="item" data-sel="' + esc(i.id) + '" aria-pressed="' + (state.selected === i.id) + '">' + kindIcon(i.kind) +
      "<span><b>" + esc(p.name) + "</b><small>" + esc(i.service || i.note) + "</small></span></button>";
  }
  function entry(a) {
    return '<div class="entry"><span class="dot ' + (a.decision.indexOf("denied") === 0 ? "no" : "yes") + '"></span><div><b>' + esc(a.op) + " " +
      esc(a.names.map(function (n) { return parts(n).name; }).join(", ")) + "</b><span>" + esc(a.decision) + " · " + esc(a.chain) + "</span>" +
      (a.cwd ? '<span class="mono">' + esc(a.cwd) + "</span>" : "") + '</div><time>' + ago(a.time) + "</time></div>";
  }

  function detail() {
    if (["activity", "grants", "deleted"].indexOf(state.filter) >= 0) return "";
    var i = items.filter(function (x) { return x.id === state.selected && matches(state.filter, x); })[0];
    if (!i) return '<div class="detail"><p class="empty">Select an item.</p></div>';
    var p = parts(i.id), shown = state.revealed[i.id];
    var mine = activity.filter(function (a) { return a.names.indexOf(i.id) >= 0; }).slice(0, 3);
    return '<div class="detail">' +
      '<div class="pane-card head">' + kindIcon(i.kind).replace("ki ", "ki big ") + '<div><b class="dn">' + esc(p.name) + "</b>" +
      "<span>" + (p.project ? esc(p.project) + ' <span class="env env-' + p.env.split(".").pop() + '">' + esc(p.env) + "</span>" : "Shared") + "</span></div></div>" +
      '<div class="pane-card"><div class="kv"><span>Value</span><code class="val">' + (shown ? esc(i.sample) : "••••••••••••••") + "</code>" +
      '<button type="button" class="ib" data-reveal="' + esc(i.id) + '" aria-label="' + (shown ? "Hide the value" : "Show the value") + '">' + (shown ? "Hide" : "Show") + "</button></div>" +
      '<div class="kv"><span>Reference</span><code>latchkey://' + esc(i.id) + '</code><button type="button" class="ib" data-copy="latchkey://' + esc(i.id) + '">Copy</button></div></div>' +
      '<div class="pane-card"><div class="kv"><span>Kind</span><em>' + KINDS[i.kind][1] + "</em></div>" +
      '<div class="kv"><span>Allow reads without approval<small>' + (i.safe ? "Any program in your Mac account may request this value." : "Reads ask unless a grant covers them.") +
      '</small></span><button type="button" class="switch" role="switch" aria-checked="' + i.safe + '" data-safe="' + esc(i.id) + '" aria-label="Allow reads without approval"><i></i></button></div>' +
      '<div class="kv"><span>Project</span><em>' + (p.project ? esc(p.project) + " / " + esc(p.env) : "Shared") + "</em></div>" +
      '<div class="kv"><span>Service</span><em>' + esc(i.service) + "</em></div>" +
      (i.note ? '<div class="kv"><span>Note</span><em>' + esc(i.note) + "</em></div>" : "") + "</div>" +
      '<p class="fn">' + (i.kind === "value" ? "Plain values are not masked in output." : "Masked in command output.") + "</p>" +
      (i.used.length ? '<p class="dh">Used In</p><div class="pane-card"><code>' + i.used.map(esc).join("<br>") + "</code></div>" : "") +
      '<p class="dh">Remote</p><div class="pane-card"><p class="muted">' + (i.remote ? "Linked: " + esc(i.remote) : esc(p.project ? p.project + "/" + p.env : "Shared items") + " isn't linked to Vercel, GitHub Actions, Railway or Fly.") + "</p></div>" +
      '<p class="dh">History</p><div class="pane-card">' + (i.history ? i.history.map(function (h) { return '<p class="muted">' + esc(h.when) + ", " + esc(h.why) + "</p>"; }).join("")
        : '<p class="muted">No earlier values yet. When this value changes, the old one is kept here.</p>') + "</div>" +
      '<p class="fn">The last 10 values are kept. Restoring keeps the current value too.</p>' +
      (mine.length ? '<p class="dh">Recent Activity</p><div class="pane-card">' + mine.map(entry).join("") + "</div>" : "") +
      "</div>";
  }

  function render() {
    var focusKey = document.activeElement && root.contains(document.activeElement) ?
      ["data-f", "data-sel", "data-open", "data-reveal", "data-safe", "data-revoke"].map(function (a) { var v = document.activeElement.getAttribute(a); return v ? "[" + a + '="' + v + '"]' : ""; }).join("") : "";
    root.querySelector(".body").innerHTML = side() + list() + detail();
    if (focusKey) { var el = root.querySelector(focusKey); if (el) el.focus({ preventScroll: true }); }
  }

  // The Touch ID sheet's icon: a fingerprint with Latchkey's mark, as macOS draws it for the app.
  var FINGERPRINT = '<svg viewBox="0 0 48 48" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round">' +
    '<path d="M14 30c0-7 4-12 10-12s10 5 10 12"/><path d="M18 34c0-6 2-10 6-10s6 4 6 10"/><path d="M24 30v8"/>' +
    '<path d="M10 26c1-9 7-15 14-15s13 6 14 15"/><path d="M12 16c3-4 7-6 12-6s9 2 12 6"/></g></svg>' +
    '<img src="' + (document.querySelector('link[rel="icon"]') || { getAttribute: function () { return "logo.svg"; } }).getAttribute("href") + '" alt="">';
  root.innerHTML = '<div class="chrome"><i></i><i></i><i></i><span>Latchkey</span></div><div class="body"></div>' +
    '<div class="touch" hidden role="dialog" aria-label="Touch ID"><div class="touch-icon">' + FINGERPRINT +
    '</div><p class="touch-text"></p><p class="touch-sub">Touch ID or enter your password to continue with Latchkey.</p>' +
    '<button type="button" class="touch-btn" data-t="pw">Use Password…</button><button type="button" class="touch-btn" data-t="deny">Deny</button></div>';
  render();
  setInterval(function () { if (state.filter === "activity") render(); }, 30000);

  root.addEventListener("click", async function (e) {
    var b = e.target.closest("button");
    if (!b || !root.contains(b) || b.closest(".touch")) return;
    if (b.dataset.f) { state.filter = b.dataset.f; render(); return; }
    if (b.dataset.open) { state.open[b.dataset.open] = !state.open[b.dataset.open]; render(); return; }
    if (b.dataset.sel) { state.selected = b.dataset.sel; render(); return; }
    if (b.dataset.copy) {
      var text = b.dataset.copy;
      (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(function () { b.textContent = "Copied"; }, function () { b.textContent = "⌘C"; });
      setTimeout(function () { b.textContent = "Copy"; }, 1400);
      return;
    }
    if (b.dataset.reveal) {
      var id = b.dataset.reveal, p = parts(id);
      if (state.revealed[id]) { delete state.revealed[id]; render(); return; }
      var unrestricted = items.some(function (item) { return item.id === id && item.safe; });
      if (unrestricted || await touchID("Latchkey is trying to release " + p.name + (p.project ? " from " + p.project + "/" + p.env : "") + " to the Latchkey app.")) {
        state.revealed[id] = true; log("get", [id], unrestricted ? "allowed (No Approval)" : "approved"); render();
        setTimeout(function () { delete state.revealed[id]; render(); }, 15000);
      } else { log("get", [id], "denied"); render(); }
      return;
    }
    if (b.dataset.safe) {
      var item = items.filter(function (x) { return x.id === b.dataset.safe; })[0], want = !item.safe, q = parts(item.id);
      if (await touchID("Latchkey is trying to " + (want ? "allow reads without approval for " : "require approval unless granted for ") + q.name + (q.project ? " from " + q.project + "/" + q.env : "") + ".")) {
        item.safe = want; log("update", [item.id], "approved"); render();
      }
      return;
    }
    if (b.dataset.revoke) {
      var g = grants.filter(function (x) { return x.id === b.dataset.revoke; })[0];
      grants = grants.filter(function (x) { return x !== g; });
      log("revoke", g.names, "revoked 1 grant");
      document.dispatchEvent(new CustomEvent("lk:revoke", { detail: { id: g.id } }));
      render();
    }
  });

  document.addEventListener("lk:activity", function (e) { activity.unshift(e.detail); render(); });
  document.addEventListener("lk:grant", function (e) { grants.unshift(e.detail); render(); });
})();
