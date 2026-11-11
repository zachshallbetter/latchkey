// Copy buttons, and `lk` commands coloured by part with an explanation of each, shown on hover or focus.
(function () {
  // ---- What each part of an lk command means (from the CLI reference).
  var ACTIONS = {
    run: "Start a command with its latchkey:// references filled in",
    import: "Move an env file's values into iCloud Keychain",
    grant: "Let commands read these items without asking, within limits",
    grants: "Grants in effect, with time left and limits",
    revoke: "End a grant, or all of them",
    touched: "What Latchkey released in a window of time",
    rotate: "Replace items one by one; the old values stay in history",
    check: "What a run would get without asking. Asks nothing, releases nothing",
    get: "Print one value",
    list: "Item IDs, kinds and agent-safe. Never values",
    set: "Add or change an item; the value comes from standard input",
    update: "Change settings on many items at once",
    rm: "Delete items; they can be restored for 30 days",
    mv: "Move items to another project or environment",
    history: "Earlier values of an item: when and by whom. Never values",
    restore: "Put back an earlier value, or a deleted item",
    push: "Send an environment's values to its linked services",
    remote: "Link environments to Vercel, GitHub Actions, Railway or Fly",
    mcp: "Serve Latchkey's tools to an agent over MCP",
    log: "The access log: every release, change and refusal",
    status: "Where values are kept, and how you approve"
  };
  var FLAGS = {
    "--env": ["Load an environment's items without an env file", "project/environment"],
    "--env-file": ["Load KEY=VALUE lines from this file first", "an env file"],
    "--file": ["Set a variable to the path of a temporary file holding an item", "NAME=ID"],
    "--no-masking": ["Don't hide values in the command's output"],
    "--proxy": ["Keep OpenAI and Anthropic keys out of the command; Latchkey adds them on the way to the provider"],
    "--aws-session": ["Give the command short-lived AWS credentials instead of your key"],
    "--aws-role": ["Assume this AWS role for short-lived credentials", "an IAM role ARN"],
    "--aws-for": ["How long the AWS credentials last (15 minutes by default)", "a time, such as 1h"],
    "--rewrite": ["Replace each imported value in the file with its reference"],
    "--scan": ["Find every .env and .env.* under this folder", "a folder"],
    "--batch": ["Also import the files listed in this file", "a list of paths"],
    "--dry-run": ["Show what would happen; send nothing"],
    "--share-identical": ["Make a value that's the same in every file one shared item"],
    "--agent-safe-pattern": ["Import matching names as values agents may read", "patterns, such as NEXT_PUBLIC_*"],
    "--project": ["Put items in this project", "a project"],
    "--session": ["End the grant when the agent you run this under quits"],
    "--command": ["Only for this command, run through lk run", "the command"],
    "--once": ["End the grant after one use"],
    "--for": ["How long", "a time: 30m, 2h, 1d"],
    "--folder": ["The folder the grant covers (default: here)", "a folder"],
    "--since": ["How far back", "a time: 4h, 2d"],
    "--by": ["Only what went to programs started under this one", "a program name"],
    "--grant": ["Only what one grant released", "a grant ID"],
    "--touched": ["Rotate what lk touched lists"],
    "--open": ["Open each service's page for making a new key"],
    "--push": ["Push the new values to linked environments"],
    "--only": ["Only these", "item IDs or keys"],
    "--to": ["Only this link", "a link ID"],
    "--json": ["Print JSON"],
    "--verify": ["Check that no entry was changed, removed or added"],
    "--limit": ["How many", "a number"],
    "--kind": ["token, password, key or value", "a kind"],
    "--agent-safe": ["Any program in your Mac account may request it without approval"]
  };
  var TIP = {
    program: "Latchkey's command-line tool (latchkey, or lk for short)",
    sep: "Everything after this is the command lk starts",
    item: "An item: NAME, project/environment/NAME, or a project/environment/* pattern",
    comment: ""
  };

  function esc(t) { return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  function tok(cls, text, tip, focusable) {
    return '<span class="tok ' + cls + '"' + (tip ? ' data-tip="' + esc(tip) + '"' : "") +
           (tip && focusable ? ' tabindex="0"' : "") + ">" + esc(text) + "</span>";
  }

  // Words, keeping quoted strings whole, with the spaces between them.
  function words(line) { return line.match(/'[^']*'|"[^"]*"|\s+|[^\s'"]+/g) || []; }

  /// One line of shell as HTML. Only lines that run lk or latchkey are coloured.
  function highlight(line, opts) {
    var focusable = !(opts && opts.inert);
    var m = line.match(/^(\s*(?:\$\s+)?)(lk|latchkey)(\s.*)?$/);
    if (!m) return esc(line);
    var html = esc(m[1]) + tok("t-prog", m[2], TIP.program);
    var parts = words(m[3] || ""), action = null, expect = null, child = false;
    for (var i = 0; i < parts.length; i++) {
      var w = parts[i];
      if (/^\s+$/.test(w)) { html += w; continue; }
      if (w[0] === "#") { html += tok("t-comment", parts.slice(i).join("")); break; }
      if (child) { html += tok("t-child", w); continue; }
      if (w === "--") { html += tok("t-sep", w, TIP.sep, focusable); child = true; continue; }
      if (expect) { html += tok("t-val", w, expect, focusable); expect = null; continue; }
      if (w.indexOf("--") === 0) {
        var f = FLAGS[w.split("=")[0]];
        html += tok("t-flag", w, f ? f[0] : null, focusable);
        if (f && f[1] && w.indexOf("=") < 0) expect = f[1];
        continue;
      }
      if (!action && ACTIONS[w]) { action = w; html += tok("t-act", w, ACTIONS[w], focusable); continue; }
      // In lk run, the first word that isn't an option starts the command.
      if (action === "run") { child = true; html += tok("t-child", w); continue; }
      html += tok("t-val", w, action === "import" ? "The env file" : TIP.item, focusable);
    }
    return html;
  }
  window.LK = { highlight: highlight, actions: ACTIONS, flags: FLAGS };

  // ---- Colour every code block that runs lk. The developer pages explain every option in their tables, so there
  // the explanations come on hover only and the parts don't add stops to the keyboard's path.
  var docs = !!document.querySelector("main.docs");
  document.querySelectorAll("pre code").forEach(function (code) {
    var text = code.textContent;
    if (code.dataset.lang && code.dataset.lang !== "bash") return;   // synopses and file contents stay as written
    if (!/(^|\n)\s*(\$\s+)?(lk|latchkey)\s/.test(text)) return;
    code.innerHTML = text.split("\n").map(function (l) { return highlight(l, { inert: docs }); }).join("\n");
    // One stop per block: Tab reaches its first explained part, the arrow keys move between parts.
    var parts = code.querySelectorAll(".tok[tabindex]");
    parts.forEach(function (t, i) { t.tabIndex = i === 0 ? 0 : -1; });
    if (parts.length) code.addEventListener("keydown", function (e) {
      var i = Array.prototype.indexOf.call(parts, document.activeElement);
      if (i < 0) return;
      var next = { ArrowRight: i + 1, ArrowDown: i + 1, ArrowLeft: i - 1, ArrowUp: i - 1, Home: 0, End: parts.length - 1 }[e.key];
      if (next === undefined) return;
      e.preventDefault();
      next = Math.max(0, Math.min(parts.length - 1, next));
      parts[i].tabIndex = -1; parts[next].tabIndex = 0; parts[next].focus();
    });
  });

  // ---- One explanation box, shown beside the part under the pointer or in focus.
  var box = document.createElement("div");
  box.className = "tok-tip";
  box.setAttribute("role", "tooltip");
  box.id = "tok-tip";
  box.hidden = true;
  document.body.appendChild(box);
  var shown = null;
  function show(el) {
    if (!el || !el.dataset.tip) return;
    shown = el;
    box.textContent = el.dataset.tip;
    box.hidden = false;
    el.setAttribute("aria-describedby", "tok-tip");
    var r = el.getBoundingClientRect(), b = box.getBoundingClientRect();
    var left = Math.max(8, Math.min(window.innerWidth - b.width - 8, r.left + r.width / 2 - b.width / 2));
    var top = r.top - b.height - 8;
    if (top < 8) top = r.bottom + 8;
    box.style.left = left + "px";
    box.style.top = top + window.scrollY + "px";
  }
  function hide() {
    if (shown) shown.removeAttribute("aria-describedby");
    shown = null;
    box.hidden = true;
  }
  document.addEventListener("mouseover", function (e) {
    var t = e.target.closest && e.target.closest(".tok[data-tip]");
    if (t) show(t); else if (shown && !shown.contains(document.activeElement)) hide();
  });
  document.addEventListener("focusin", function (e) { if (e.target.matches && e.target.matches(".tok[data-tip]")) show(e.target); });
  document.addEventListener("focusout", function (e) { if (e.target === shown) hide(); });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") hide(); });
  window.addEventListener("scroll", hide, { passive: true });

  // ---- Copy buttons. Copy only the block's own text.
  document.querySelectorAll("button.copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var code = btn.closest("figure").querySelector("code");
      var text = code ? code.textContent : "";
      function done(ok) {
        btn.textContent = ok ? "Copied" : "Press ⌘C";
        if (ok) btn.setAttribute("data-done", "");
        setTimeout(function () { btn.textContent = "Copy"; btn.removeAttribute("data-done"); }, 1600);
      }
      function select() {
        var r = document.createRange(); r.selectNodeContents(code);
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); }, function () { select(); done(false); });
      } else { select(); done(false); }
    });
  });
})();
