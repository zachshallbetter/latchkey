// A working copy of the Latchkey window with example data, laid out as the app is: the sidebar (All Items, Review,
// Activity, projects, services, Grants, Recently Deleted), a flat list of two-line rows with search and filters, and
// the item's detail as cards. Icons and their colours follow the app's ItemType (App/Latchkey/Style.swift). What the
// visitor does in the approval scene on the home page arrives here as lk:activity and lk:grant events; elsewhere it
// starts from the example data. Revealing or copying a value and changing access ask for Touch ID, as the app does.
(function () {
  var root = document.getElementById("appwin");
  if (!root) return;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  function ic(name) { return '<i class="ic ic-' + name + '" aria-hidden="true"></i>'; }
  function ago(d) {
    var s = Math.round((Date.now() - d) / 1000);
    if (s < 60) return "just now";
    if (s < 3600) return Math.round(s / 60) + " minutes ago";
    var h = Math.round(s / 3600);
    return h === 1 ? "1 hour ago" : h + " hours ago";
  }

  // ---- Example data. Values are made up and say so.
  var ENV_FILE = "~/Projects/shop/.env.local";
  var items = [
    { id: "shop/development/DATABASE_URL", kind: "password", service: "Neon", safe: false, note: "imported from .env.local", loc: ENV_FILE, sample: "postgres://app:example-only@db.neon.tech/shop" },
    { id: "shop/development/STRIPE_KEY", kind: "token", service: "Stripe", safe: false, note: "imported from .env.local", loc: ENV_FILE, sample: "sk_test_example-only" },
    { id: "shop/development/PGHOST", kind: "value", service: "Neon", safe: true, note: "imported from .env.local", loc: ENV_FILE, sample: "ep-example.us-east-2.aws.neon.tech" },
    { id: "shop/development/NEXT_PUBLIC_SITE_URL", kind: "value", service: "", safe: true, note: "imported from .env.local", loc: ENV_FILE, sample: "http://localhost:3000" },
    { id: "shop/preview/DATABASE_URL", kind: "password", service: "Neon", safe: false, note: "", loc: "", sample: "postgres://preview:example-only@db.neon.tech/shop", remote: "notPushed" },
    { id: "shop/production/DATABASE_URL", kind: "password", service: "Neon", safe: false, note: "", loc: "", sample: "postgres://prod:example-only@db.neon.tech/shop",
      history: [{ when: "Oct 28", why: "replaced by zsh › Terminal" }] },
    { id: "shop/production/STRIPE_KEY", kind: "token", service: "Stripe", safe: false, note: "", loc: "", sample: "sk_live_example-only", remote: "outOfDate" },
    { id: "blog/development/ADMIN_PASSWORD", kind: "password", service: "", safe: false, note: "imported from .env", loc: "~/Projects/blog/.env", sample: "example-only-password" },
    { id: "blog/development/SENTRY_DSN", kind: "password", service: "Sentry", safe: false, note: "imported from .env", loc: "~/Projects/blog/.env", sample: "https://example-only@sentry.io/1" },
    { id: "blog/development/GITHUB_TOKEN", kind: "token", service: "GitHub", safe: false, note: "imported from .env", loc: "~/Projects/blog/.env", sample: "ghp_example-only" },
    { id: "api/production/ASC_P8", kind: "key", service: "App Store Connect", safe: false, note: "key file", loc: "", sample: "-----BEGIN PRIVATE KEY----- example-only" },
    { id: "api/development/API_BASE_URL", kind: "value", service: "", safe: true, note: "", loc: "~/Projects/api/.env.local", sample: "http://localhost:8080" },
    { id: "OPENAI_API_KEY", kind: "token", service: "OpenAI", safe: false, note: "shared by every project", loc: "", sample: "sk-proj-example-only" },
    { id: "ANTHROPIC_API_KEY", kind: "token", service: "Anthropic", safe: false, note: "shared by every project", loc: "", sample: "sk-ant-example-only" }
  ];
  var KINDS = { token: "Token", password: "Password", key: "Key File", value: "Plain Value" };
  var activity = [
    { op: "Read", names: ["shop/development/PGHOST"], decision: "Allowed (agent-safe)", who: "Claude", time: new Date(Date.now() - 40 * 60e3) },
    { op: "Read", names: ["shop/development/DATABASE_URL", "shop/development/STRIPE_KEY"], decision: "Approved", who: "Claude", time: new Date(Date.now() - 42 * 60e3) },
    { op: "Import", names: ["shop/development/DATABASE_URL", "shop/development/STRIPE_KEY", "shop/development/PGHOST", "shop/development/NEXT_PUBLIC_SITE_URL"],
      decision: "Approved", who: "Terminal", time: new Date(Date.now() - 2 * 3600e3) }
  ];
  var grants = [];
  var state = { filter: "all", selected: items[0].id, query: "", type: "", env: "", revealed: {} };

  function parts(id) { var p = id.split("/"); return p.length === 3 ? { project: p[0], env: p[1], name: p[2] } : { project: "", env: "", name: id }; }
  // The app's ItemType: the icon, colour and label for an item, from its kind and name.
  function type(i) {
    var n = parts(i.id).name.toUpperCase();
    var address = /(_URL|_URI|_ENDPOINT)$/.test(n) || n === "URL";
    var database = ["DATABASE", "POSTGRES", "MYSQL", "REDIS", "MONGO", "_DSN"].some(function (w) { return n.indexOf(w) >= 0; });
    if (i.kind === "key") return ["Key File", "keyfile", "purple"];
    if ((i.kind === "value" || i.kind === "token") && address) return ["URL", "globe", "teal"];
    if (i.kind === "value") return ["Plain Value", "tag", "gray"];
    if (i.kind === "password" && database) return ["Database", "db", "orange"];
    if (i.kind === "password") return ["Password", "lock", "yellow"];
    if (/_KEY$/.test(n)) return ["API Key", "code", "indigo"];
    return ["Token", "key", "blue"];
  }
  function projects() { return Array.from(new Set(items.map(function (i) { return parts(i.id).project; }).filter(Boolean))).sort(); }
  function services() { return Array.from(new Set(items.map(function (i) { return i.service; }).filter(Boolean))).sort(); }
  function inFilter(f, i) {
    if (f === "all") return true;
    if (f === "shared") return !parts(i.id).project;
    if (f.indexOf("project:") === 0) return parts(i.id).project === f.slice(8);
    if (f.indexOf("service:") === 0) return i.service === f.slice(8);
    return false;
  }
  function shown() {
    var q = state.query.toLowerCase();
    return items.filter(function (i) {
      return inFilter(state.filter, i) && (!q || i.id.toLowerCase().indexOf(q) >= 0 || (i.service || "").toLowerCase().indexOf(q) >= 0) &&
        (!state.type || type(i)[0] === state.type) && (!state.env || parts(i.id).env === state.env);
    }).sort(function (a, b) { return parts(a.id).name.localeCompare(parts(b.id).name) || a.id.localeCompare(b.id); });
  }
  function count(f) { return items.filter(function (i) { return inFilter(f, i); }).length; }
  function findings() {
    var out = [];
    items.forEach(function (i) {
      if (i.remote === "outOfDate") out.push({ id: i.id, title: "Changed since it was last pushed", detail: "Vercel still has the earlier value. Push the environment to update it.", icon: "sync", tint: "orange" });
      if (i.remote === "notPushed") out.push({ id: i.id, title: "Not pushed yet", detail: "Its environment is linked to Vercel, which doesn't have this value.", icon: "cloudoff", tint: "gray" });
    });
    grants.forEach(function (g) { out.push({ id: g.names[0], title: "Grant for " + g.folder, detail: g.limits.charAt(0).toUpperCase() + g.limits.slice(1) + ".", icon: "shieldcheck", tint: "teal" }); });
    return out;
  }
  function env(e) { return '<span class="env env-' + esc(e) + '">' + esc(e) + "</span>"; }

  // ---- Touch ID inside the window, for reveals, copies and changes made in the app.
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
  function log(op, names, decision) { activity.unshift({ op: op, names: names, decision: decision, who: "Latchkey", time: new Date() }); }

  // ---- Rendering
  function nav(f, label, icon, n, badge) {
    return '<li><button type="button" data-f="' + esc(f) + '" aria-pressed="' + (state.filter === f) + '">' + icon + "<span>" + esc(label) + "</span>" +
      (n === null || n === undefined ? "" : '<em class="' + (badge ? "badge" : "") + '">' + n + "</em>") + "</button></li>";
  }
  function side() {
    var nf = findings().length;
    return '<div class="side"><div class="brand-row"><img src="' + logo + '" alt=""><div><b>Latchkey</b><span>Development secrets</span></div></div>' +
      '<ul class="navs">' + nav("all", "All Items", ic("grid"), items.length) + nav("review", "Review", ic("shield"), nf || null, true) +
      nav("activity", "Activity", ic("pulse")) + "</ul>" +
      '<p class="sh">Projects</p><ul>' + projects().map(function (p) { return nav("project:" + p, p, ic("folder"), count("project:" + p)); }).join("") +
      nav("shared", "Shared", ic("tray"), count("shared")) + "</ul>" +
      '<p class="sh">Services</p><ul>' + services().map(function (s) {
        return nav("service:" + s, s, '<span class="svc">' + esc(s.charAt(0)) + "</span>", count("service:" + s));
      }).join("") + "</ul>" +
      '<ul class="navs low">' + nav("grants", "Grants", ic("shieldcheck"), grants.length || null) + nav("deleted", "Recently Deleted", ic("trash")) + "</ul>" +
      '<p class="store">' + ic("cloud") + "<b>iCloud Keychain</b><i></i>On</p></div>";
  }
  function heading() {
    if (state.filter === "all") return "All Items";
    if (state.filter === "shared") return "Shared";
    return state.filter.split(":")[1];
  }
  function list() {
    var f = state.filter;
    if (f === "activity") return '<div class="list wide"><div class="lh"><div><b>Activity</b><span>' + activity.length + " entries</span></div></div>" + activity.map(entry).join("") + "</div>";
    if (f === "review") {
      var fs = findings();
      return '<div class="list wide"><div class="lh"><div><b>Review</b><span>What may need a look</span></div></div>' +
        (fs.length ? fs.map(function (x) {
          var p = parts(x.id);
          return '<button type="button" class="finding" data-go="' + esc(x.id) + '"><span class="tint-' + x.tint + '">' + ic(x.icon) + "</span><span><b>" + esc(p.name) +
            "</b><small>" + esc(x.title) + (p.project ? " · " + esc(p.project) + " · " + esc(p.env) : "") + "</small><small>" + esc(x.detail) + "</small></span>" + ic("chevright") + "</button>";
        }).join("") : '<p class="empty">Nothing to review.</p>') + "</div>";
    }
    if (f === "grants") {
      return '<div class="list wide"><div class="lh"><div><b>Grants</b><span>' + grants.length + " in effect</span></div></div>" +
        (grants.length ? grants.map(function (g) {
          return '<div class="grantrow">' + ic("shieldcheck") + "<div><b>" + esc(g.folder) + "</b><span>" + esc(g.names.map(function (n) { return parts(n).name; }).join(", ")) +
            " · " + esc(g.limits) + '</span></div><button type="button" class="pill" data-revoke="' + g.id + '">Revoke</button></div>';
        }).join("") : '<p class="empty">No grants in effect. Choose “Allow from this folder” in the approval panel above to make one.</p>') + "</div>";
    }
    if (f === "deleted") return '<div class="list wide"><div class="lh"><div><b>Recently Deleted</b><span>Kept for 30 days</span></div></div><p class="empty">Nothing deleted in the last 30 days.</p></div>';
    var rows = shown();
    var html = '<div class="list"><div class="lh"><div><b>' + esc(heading()) + "</b><span>" + rows.length + " items · " + projects().length + " projects · " + services().length +
      ' services</span></div><span class="newb">' + ic("plus") + "New Item</span></div>" +
      '<label class="search">' + ic("search") + '<input type="search" placeholder="Search items…" value="' + esc(state.query) + '" aria-label="Search items"><kbd>⌘F</kbd></label>' +
      '<div class="filters"><button type="button" data-cycle="type">' + esc(state.type || "Type") + ic("chevdown") + '</button><button type="button" data-cycle="env">' +
      esc(state.env || "Environment") + ic("chevdown") + '</button><span class="opts">' + ic("menu") + "</span></div><div class=\"rows\">";
    html += rows.length ? rows.map(row).join("") : '<p class="empty">No items match.</p>';
    return html + "</div></div>";
  }
  function row(i) {
    var p = parts(i.id), t = type(i);
    var sub = (p.project ? [p.project, p.env] : ["Shared"]).concat(i.service ? [i.service] : []).join(" · ");
    return '<button type="button" class="item" data-sel="' + esc(i.id) + '" aria-pressed="' + (state.selected === i.id) + '"><span class="ti tint-' + t[2] + '" title="' + t[0] + '">' + ic(t[1]) +
      "</span><span><b>" + esc(p.name) + "</b><small>" + esc(sub) + "</small></span>" +
      (i.remote === "outOfDate" ? '<span class="flag tint-orange" title="Changed since it was last pushed to a remote location">' + ic("sync") + "</span>" : "") +
      (i.remote === "notPushed" ? '<span class="flag tint-gray" title="Not pushed yet to a remote location its environment is linked to">' + ic("cloudoff") + "</span>" : "") +
      (i.safe ? '<span class="flag tint-green" title="Any program in your Mac account may request this value without approval">' + ic("agent") + "</span>" : "") + "</button>";
  }
  function entry(a) {
    var icon = { Read: "eye", Import: "download", Update: "pencil", Revoke: "x", Copy: "copy" }[a.op] || "pulse";
    var denied = a.decision.indexOf("Denied") === 0;
    return '<div class="entry">' + '<span class="' + (denied ? "tint-red" : "") + '">' + ic(denied ? "ban" : icon) + "</span><div><b>" + esc(a.op) + "</b><span>" + esc(a.decision) +
      " · " + esc(a.names.map(function (n) { return parts(n).name; }).join(", ")) + '</span></div><div class="when"><span>' + ic("person") + esc(a.who) + "</span><time>" + ago(a.time) + "</time></div></div>";
  }
  function detail() {
    if (["activity", "review", "grants", "deleted"].indexOf(state.filter) >= 0) return "";
    var i = shown().filter(function (x) { return x.id === state.selected; })[0] || shown()[0];
    if (!i) return '<div class="detail"><p class="empty">Select an item.</p></div>';
    state.selected = i.id;
    var p = parts(i.id), t = type(i), open = state.revealed[i.id];
    var mine = activity.filter(function (a) { return a.names.indexOf(i.id) >= 0; }).slice(0, 4);
    function kv(k, v) { return '<div class="kv"><span>' + k + "</span>" + v + "</div>"; }
    return '<div class="detail">' +
      '<div class="pane-card head"><span class="tile tint-' + t[2] + '">' + ic(t[1]) + '</span><div><b class="dn">' + esc(p.name) + "</b><span>" +
      (p.project ? '<span class="pchip">' + esc(p.project) + "</span>" + env(p.env) : '<span class="pchip">Shared</span>') + '</span></div><span class="editb">' + ic("pencil") + "Edit</span></div>" +
      '<div class="pane-card">' +
      kv("Value", '<code class="val">' + (open ? esc(i.sample) : "••••••••••••••") + '</code><button type="button" class="ib" data-reveal="' + esc(i.id) + '" aria-label="' +
        (open ? "Hide the value" : "Show the value") + '">' + ic(open ? "eyeoff" : "eye") + '</button><button type="button" class="ib" data-copyvalue="' + esc(i.id) + '" aria-label="Copy the value">' + ic("copy") + "</button>") +
      kv("Reference", '<code class="ref">latchkey://' + esc(i.id) + '</code><button type="button" class="ib" data-copy="latchkey://' + esc(i.id) + '" aria-label="Copy the reference">' + ic("copy") + "</button>") +
      "</div>" +
      '<div class="pane-card">' +
      kv("Type", '<em><span class="tint-' + t[2] + '">' + ic(t[1]) + "</span>" + t[0] + "</em>") +
      kv("Access", '<em>' + (i.safe ? "No approval" : "Ask first") + '</em><button type="button" class="switch" role="switch" aria-checked="' + i.safe + '" data-safe="' + esc(i.id) +
        '" aria-label="Allow reads without approval"><i></i></button>') +
      kv("Service", "<em>" + esc(i.service || "None") + "</em>") +
      kv("Project", "<em>" + (p.project ? ic("folder") + esc(p.project) : ic("tray") + "Shared") + "</em>") +
      (p.project ? kv("Environment", "<em>" + env(p.env) + "</em>") : "") +
      (i.note ? kv("Note", "<em>" + esc(i.note) + "</em>") : "") +
      (i.loc ? kv("Location", '<em class="loc">' + ic("folder") + esc(i.loc) + ic("chevright") + "</em>") : "") +
      "</div>" +
      '<div class="pane-card"><p class="ch">' + ic("history") + "History</p>" + (i.history ? i.history.map(function (h) { return '<p class="muted">' + esc(h.when) + ", " + esc(h.why) + "</p>"; }).join("")
        : '<p class="muted">No earlier values yet. The last 10 are kept when it changes.</p>') + "</div>" +
      '<div class="pane-card"><p class="ch">' + ic("pulse") + "Recent Activity</p>" + (mine.length ? mine.map(entry).join("") : '<p class="muted">Nothing has read it yet.</p>') + "</div>" +
      "</div>";
  }

  function render() {
    var act = document.activeElement, focusKey = "", caret = null;
    if (act && root.contains(act)) {
      if (act.matches(".search input")) { focusKey = ".search input"; caret = act.selectionStart; }
      else focusKey = ["data-f", "data-sel", "data-reveal", "data-safe", "data-revoke", "data-cycle", "data-copy", "data-copyvalue", "data-go"].map(function (a) {
        var v = act.getAttribute(a); return v ? "[" + a + '="' + v + '"]' : ""; }).join("");
    }
    root.querySelector(".body").innerHTML = side() + list() + detail();
    if (focusKey) {
      var el = root.querySelector(focusKey);
      if (el) { el.focus({ preventScroll: true }); if (caret !== null) el.setSelectionRange(caret, caret); }
    }
  }

  // The Touch ID sheet's icon: a fingerprint with Latchkey's mark, as macOS draws it for the app.
  var logo = (document.querySelector('link[rel="icon"]') || { getAttribute: function () { return "logo.svg"; } }).getAttribute("href");
  root.innerHTML = '<div class="chrome"><i></i><i></i><i></i><span class="sb">' + ic("sidebar") + '</span></div><div class="body"></div>' +
    '<div class="touch" hidden role="dialog" aria-label="Touch ID"><div class="touch-icon">' + ic("fingerprint") + '<img src="' + logo + '" alt=""></div>' +
    '<p class="touch-text"></p><p class="touch-sub">Touch ID or enter your password to continue with Latchkey.</p>' +
    '<button type="button" class="touch-btn" data-t="pw">Use Password…</button><button type="button" class="touch-btn" data-t="deny">Deny</button></div>';
  render();
  setInterval(function () { if (!root.contains(document.activeElement) || !document.activeElement.matches(".search input")) render(); }, 60000);

  var CYCLE = { type: ["", "Token", "API Key", "Database", "Password", "URL", "Plain Value", "Key File"], env: ["", "development", "preview", "production"] };
  root.addEventListener("input", function (e) { if (e.target.matches(".search input")) { state.query = e.target.value; render(); } });
  root.addEventListener("click", async function (e) {
    var b = e.target.closest("button");
    if (!b || !root.contains(b) || b.closest(".touch")) return;
    if (b.dataset.f) { state.filter = b.dataset.f; state.query = ""; state.type = ""; state.env = ""; render(); return; }
    if (b.dataset.go) { state.filter = "all"; state.selected = b.dataset.go; render(); return; }
    if (b.dataset.sel) { state.selected = b.dataset.sel; render(); return; }
    if (b.dataset.cycle) { var c = CYCLE[b.dataset.cycle], k = b.dataset.cycle; state[k] = c[(c.indexOf(state[k]) + 1) % c.length]; render(); return; }
    if (b.dataset.copy) {
      var text = b.dataset.copy;
      (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(function () { b.classList.add("done"); }, function () {});
      setTimeout(function () { b.classList.remove("done"); }, 1400);
      return;
    }
    if (b.dataset.reveal || b.dataset.copyvalue) {
      var id = b.dataset.reveal || b.dataset.copyvalue, p = parts(id), item = items.filter(function (x) { return x.id === id; })[0];
      if (b.dataset.reveal && state.revealed[id]) { delete state.revealed[id]; render(); return; }
      if (item.safe || await touchID("Latchkey is trying to release " + p.name + (p.project ? " from " + p.project + "/" + p.env : "") + " to the Latchkey app.")) {
        if (b.dataset.reveal) {
          state.revealed[id] = true; log("Read", [id], item.safe ? "Allowed (agent-safe)" : "Approved");
          setTimeout(function () { delete state.revealed[id]; render(); }, 15000);
        } else {
          if (navigator.clipboard) navigator.clipboard.writeText(item.sample).catch(function () {});
          log("Copy", [id], item.safe ? "Allowed (agent-safe)" : "Approved");
        }
      } else log("Read", [id], "Denied");
      render();
      return;
    }
    if (b.dataset.safe) {
      var it = items.filter(function (x) { return x.id === b.dataset.safe; })[0], want = !it.safe, q = parts(it.id);
      if (await touchID("Latchkey is trying to " + (want ? "allow reads without approval for " : "require approval unless granted for ") + q.name + (q.project ? " from " + q.project + "/" + q.env : "") + ".")) {
        it.safe = want; log("Update", [it.id], want ? "No approval" : "Ask first"); render();
      }
      return;
    }
    if (b.dataset.revoke) {
      var g = grants.filter(function (x) { return x.id === b.dataset.revoke; })[0];
      grants = grants.filter(function (x) { return x !== g; });
      log("Revoke", g.names, "Revoked 1 grant");
      document.dispatchEvent(new CustomEvent("lk:revoke", { detail: { id: g.id } }));
      render();
    }
  });

  // From the approval scene: its own entry shape (op, names, decision, chain), shown the way the app words it.
  document.addEventListener("lk:activity", function (e) {
    var d = e.detail;
    activity.unshift({ op: d.op === "get" ? "Read" : d.op.charAt(0).toUpperCase() + d.op.slice(1), names: d.names,
      decision: d.decision.charAt(0).toUpperCase() + d.decision.slice(1), who: /claude/i.test(d.chain || "") ? "Claude" : (d.chain || "").split(" › ").pop() || "Terminal", time: d.time || new Date() });
    render();
  });
  document.addEventListener("lk:grant", function (e) { grants.unshift(e.detail); render(); });
})();
