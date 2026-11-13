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
    duplicates: "Find items holding the same value, and what to do about each. Asks every time; values are never shown",
    combine: "Make items holding one value into one shared item",
    scan: "Find env files that still hold plain values. Prints file and line, never a value",
    export: "Write an environment's env file from its record",
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
    "--proxy-models": ["With --proxy: refuse requests that don't name one of these models", "models, such as gpt-4o-mini,gpt-4o"],
    "--proxy-requests": ["With --proxy: refuse requests after this many have been forwarded", "a number"],
    "--aws-session": ["Give the command short-lived AWS credentials instead of your key"],
    "--aws-role": ["Assume this AWS role for short-lived credentials", "an IAM role ARN"],
    "--aws-for": ["How long the AWS credentials last (15 minutes by default)", "a time, such as 1h"],
    "--rewrite": ["Replace each imported value in the file with its reference"],
    "--class": ["Change how an imported line is classed: a secret, a setting left in the file, or a public value", "KEY=secret|setting|public"],
    "--merge": ["Update the variables Latchkey manages in an existing file and add the missing ones; every other byte stays"],
    "--replace": ["Overwrite what's already there: the whole env file for export, existing items for import"],
    "--yes": ["Go ahead without asking first"],
    "--out": ["Write to this file instead of standard output", "a file"],
    "--values": ["Write the values themselves in plain text. Asks every time; agents can't"],
    "--clipboard": ["Copy the values for this Mac only, hidden from clipboard managers and cleared after 60 seconds. Asks every time"],
    "--staged": ["Scan only the lines a commit would add"],
    "--install-hook": ["Write a Git pre-commit hook that refuses commits with plain values in env files"],
    "--force": ["Overwrite a pre-commit hook that isn't Latchkey's"],
    "--into": ["The shared item (or the item in their environment) to combine into", "a name or ID"],
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
    "--note": ["Free text kept with the item", "text"],
    "--kind": ["token, password, key or value", "a kind"],
    "--agent-safe": ["Any program in your Mac account may request it without approval"]
  };
  // Options that mean something else for one command.
  var ACTION_FLAGS = {
    mv: { "--file": ["Also update the references in this env file", "an env file"] },
    combine: { "--file": ["Also update the references in this env file", "an env file"] },
    export: { "--replace": ["Rewrite the whole file, losing its comments and other variables"] },
    import: { "--replace": ["Overwrite items that already exist; old values are kept as versions"] }
  };
  var POSITIONAL = { import: "The env file", scan: "The folder to scan", export: "project/environment" };
  var TIP = {
    program: "Latchkey's command-line tool (latchkey, or lk for short)",
    sep: "Everything after this is the command lk starts",
    item: "An item: NAME, project/environment/NAME, or a project/environment/* pattern",
    child: "The command lk starts, with the values filled in",
    options: "Any of the options in the table below",
    comment: ""
  };
  // Placeholders in a synopsis, such as FILE or PROJECT/ENV.
  var PLACEHOLDER = {
    FILE: "A file path", DIR: "A folder", "PROJECT/ENV": "An environment, written project/environment",
    IDS: "One or more item IDs", ID: "An item ID", NAME: "A name", COMMAND: "The command to run", ARGS: "Its arguments",
    PATTERN: "A pattern such as shop/development/*", P: "A project", TEXT: "Text", KIND: "token, password, key or value",
    HOSTS: "Website hosts, comma-separated", N: "A number", "A,B": "A comma-separated list", KEY: "A variable name",
    PATH: "A path", R: "A Git remote"
  };

  // ---- Programs other than lk that appear beside it: [what it is, its subcommands, its options, its arguments].
  var SHELL = {
    brew: ["Homebrew, the Mac package manager",
      { tap: "Adds a tap: a repository of formulas and casks", trust: "Trusts the tap, so Homebrew installs from it", install: "Installs a package" },
      { "--cask": "A Mac app rather than a command-line formula" },
      { "zachshallbetter/latchkey": "Latchkey's Homebrew tap", latchkey: "The Latchkey app" }],
    export: ["Sets a variable for this shell and the programs it starts", {}, {}, {}],
    cd: ["Changes folder", {}, {}, { "~/Projects/shop": "The project's checkout" }],
    ssh: ["Connects to the other Mac over SSH", {},
      { "-o": "An SSH option; StreamLocalBindUnlink=yes replaces a stale socket", "-R": "Forwards a socket on the other Mac to Latchkey's socket on this one" }, {}],
    claude: ["Claude Code's command-line tool", { mcp: "Manages Claude Code's MCP servers", add: "Adds a server: its name, then the command that starts it" }, {}, { latchkey: "The server's name" }],
    "/plugin": ["A Claude Code command for plugins",
      { marketplace: "Plugin marketplaces", add: "Adds a marketplace from a folder or repository", install: "Installs a plugin" },
      { "--marketplace": "The marketplace it comes from" }, { latchkey: "The Latchkey plugin" }],
    printf: ["Prints its arguments exactly, without adding a newline", {}, {}, { "%s": "Print the next argument as it is", '"$TOKEN"': "A value already in a shell variable, so it never appears in your shell history" }]
  };
  var ENVVARS = {
    LATCHKEY_SOCKET: "Where lk finds Latchkey: a socket forwarded over SSH from the Mac running it",
    LATCHKEY_NO_LAUNCH: "Don't start the app if it isn't running; fail with exit 69 instead",
    OPENAI_API_KEY: "What the command sees in place of the key: a placeholder only the proxy accepts",
    OPENAI_BASE_URL: "Points the OpenAI library at Latchkey's local proxy"
  };
  // Fields in the JSON the broker, the log, list --json and MCP clients use.
  var JSONKEYS = {
    op: "The operation", info: "Status details", approval: "How you approve", caller: "Who asked, and whether its signature was checked",
    grants: "Grants in effect", items: "How many items", socket: "The broker's socket", storage: "Where values are kept",
    ok: "Whether the request was handled", denied: "Items you refused; nothing is released if any were", masked: "Items whose values are masked in output",
    values: "Released values, by item ID", missing: "IDs that don't exist",
    agentSafe: "Read without asking", kind: "token, password, key or value", name: "The item ID", note: "Free text", service: "Who issued it, optional",
    updatedAt: "When the value or settings last changed", usedIn: "Files that reference it, recorded on import and move",
    created: "When the grant was made", createdBy: "The program chain that asked for it", expires: "When it ends",
    folder: "The folder it covers, with its subfolders", id: "The grant's ID, for lk revoke", names: "Item IDs involved",
    repo: "The repository it covers, so the checkout's worktrees are included",
    chain: "The calling process and its parents, nearest first", command: "The caller's command line, from the kernel",
    cwd: "The folder the caller ran in, from the kernel", decision: "What happened: allowed and why, denied, refused", time: "When",
    program: "The calling program's path, when it isn't Latchkey's signed command-line tool",
    mcpServers: "The MCP servers this client starts", args: "Its arguments", env: "Variables for it; latchkey:// references are filled in by lk run",
    content: "What the agent reads", type: "The kind of content", text: "The exit code and masked output, as text",
    structuredContent: "The same result as fields", exitCode: "The command's exit status", timedOut: "Whether it was stopped for running too long",
    stdout: "Standard output, masked", stdoutTruncated: "Whether standard output was cut short", stderr: "Standard error, masked",
    stderrTruncated: "Whether standard error was cut short", isError: "Whether the tool call failed",
    "some-server": "The server's name in this client", latchkey: "The server's name in this client"
  };
  var REF = {
    "latchkey://": "A reference: Latchkey fills in this item's value when the command starts",
    "latchkey-file://": "A file reference: the command gets the path of a temporary file holding the item",
    "lk-proxy-": "A placeholder key: the proxy swaps in the real one, and only for the provider's host",
    "http://127.0.0.1": "Latchkey's local proxy, which forwards requests to the provider"
  };
  var CHECK = { "agent-safe": "Read without asking", granted: "Covered by a grant, with its time left", asks: "Will ask you when the command runs", missing: "No item with that ID" };
  // Parts of the architecture diagram on the developer overview.
  var DIAGRAM = [
    ["latchkey (CLI)", "The command-line tool; it never touches the keychain"],
    ["JSON over a Unix socket", "One request per line, to a socket only your user can open"],
    ["Broker (in the app)", "The signed app, the only thing that reads the keychain"],
    ["iCloud Keychain", "Where items live, synced to your Macs"],
    ["approval panel, then Touch ID", "Every read that isn't agent-safe or granted asks you first"],
    ["access.jsonl (never values)", "The access log: one line per read, change and refusal"],
    ["keychain, this Mac only", "Grants are kept on this Mac and don't sync"],
    ["vercel, gh, railway, flyctl", "Each service's own tool, run by the app to push an environment"]
  ];

  function esc(t) { return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  function tok(cls, text, tip, focusable) {
    return '<span class="tok ' + cls + '"' + (tip ? ' data-tip="' + esc(tip) + '"' : "") +
           (tip && focusable ? ' tabindex="0"' : "") + ">" + esc(text) + "</span>";
  }

  // Words, keeping quoted strings whole, with the spaces between them.
  function words(line, synopsis) {
    return line.match(synopsis ? /'[^']*'|"[^"]*"|\s+|\.\.\.|[\[\]|]|[^\s'"\[\]|]+/g : /'[^']*'|"[^"]*"|\s+|[^\s'"]+/g) || [];
  }
  function isPlaceholder(w) { return /^[A-Z][A-Z0-9_\/,.=|-]*$/.test(w) && w.length > 0; }
  function placeholderTip(w) { return PLACEHOLDER[w] || PLACEHOLDER[w.split("=")[0]] || "A placeholder: put your own value here"; }

  /// One line of shell as HTML. Only lines that run lk or latchkey are coloured.
  function highlight(line, opts) {
    var focusable = !(opts && opts.inert);
    var syn = !!(opts && opts.synopsis);
    var m = line.match(/^(\s*(?:\$\s+)?)((?:~|\.)?[\w.\/~-]*\/)?(lk|latchkey)(\s.*)?$/);
    if (!m) return esc(line);
    var html = esc(m[1]) + tok("t-prog", (m[2] || "") + m[3], TIP.program, focusable);
    var parts = words(m[4] || "", syn), action = null, expect = null, child = false, first = true;
    for (var i = 0; i < parts.length; i++) {
      var w = parts[i];
      if (/^\s+$/.test(w)) { html += w; continue; }
      if (w[0] === "#") { html += tok("t-comment", parts.slice(i).join("")); break; }
      if (syn && /^(\[|\]|\||\.\.\.)$/.test(w)) { html += tok("t-punct", w); continue; }
      if (syn && w === "options") { html += tok("t-ph", w, TIP.options, focusable); continue; }
      if (child) {
        if (syn && isPlaceholder(w)) html += tok("t-ph", w, placeholderTip(w), focusable);
        else if (first) html += tok("t-child", w, TIP.child, focusable);
        else html += tok("t-child", w);
        first = false; continue;
      }
      if (w === "--") { html += tok("t-sep", w, TIP.sep, focusable); child = true; continue; }
      if (expect) { html += tok(syn && isPlaceholder(w) ? "t-ph" : "t-val", w, syn && isPlaceholder(w) ? placeholderTip(w) : expect, focusable); expect = null; continue; }
      if (w.indexOf("--") === 0) {
        var f = (ACTION_FLAGS[action] || {})[w.split("=")[0]] || FLAGS[w.split("=")[0]];
        html += tok("t-flag", w, f ? f[0] : null, focusable);
        if (f && f[1] && w.indexOf("=") < 0) expect = f[1];
        continue;
      }
      if (!action && ACTIONS[w]) { action = w; html += tok("t-act", w, ACTIONS[w], focusable); continue; }
      // In lk run, the first word that isn't an option starts the command.
      if (action === "run") { child = true; first = false; html += tok("t-child", w, TIP.child, focusable); continue; }
      if (syn && isPlaceholder(w)) { html += tok("t-ph", w, placeholderTip(w), focusable); continue; }
      html += tok("t-val", w, POSITIONAL[action] || TIP.item, focusable);
    }
    return html;
  }
  window.LK = { highlight: highlight, actions: ACTIONS, flags: FLAGS };

  /// A variable assignment, as in an env file or after export.
  function assign(text, focusable) {
    var m = text.match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m) return esc(text);
    var html = esc(m[1]) + tok("t-key", m[2], ENVVARS[m[2]] || "A variable the command sees", focusable) + tok("t-punct", "=");
    var v = m[3], tip = null;
    Object.keys(REF).forEach(function (p) { if (!tip && v.replace(/^["']/, "").indexOf(p) === 0) tip = REF[p]; });
    if (!v) return html;
    return html + tok(tip ? "t-ref" : "t-str", v, tip || "A plain value, kept as written", focusable);
  }

  /// One line of shell: lk lines as above, other programs from SHELL, joined by pipes and the like.
  function shell(line, opts) {
    var focusable = !(opts && opts.inert);
    var hash = line.search(/\s#\s/), comment = "";
    if (hash >= 0) { comment = line.slice(hash); line = line.slice(0, hash); }
    var html = line.split(/(\s*(?:\||&&|;)\s*)/).map(function (seg, i) {
      if (i % 2) return tok("t-punct", seg);
      if (/^\s*(?:\$\s+)?(?:(?:~|\.)?[\w.\/~-]*\/)?(lk|latchkey)(\s|$)/.test(seg)) return highlight(seg, opts);
      if (/^\s*[A-Za-z_][A-Za-z0-9_]*=/.test(seg)) return assign(seg, focusable);
      var parts = words(seg), out = "", prog = null, after = false;
      for (var j = 0; j < parts.length; j++) {
        var w = parts[j];
        if (/^\s+$/.test(w)) { out += w; continue; }
        if (!prog) { prog = SHELL[w] || ["", {}, {}, {}]; out += tok("t-prog", w, prog[0] || null, focusable); continue; }
        if (after) { out += highlight(parts.slice(j).join(""), opts); break; }
        if (w === "--") { out += tok("t-sep", w, "Everything after this is the command it starts", focusable); after = true; continue; }
        if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w) && !prog[2][parts[j - 2]]) { out += assign(w, focusable); continue; }
        if (w[0] === "-") { out += tok("t-flag", w, prog[2][w] || null, focusable); continue; }
        if (prog[1][w]) { out += tok("t-act", w, prog[1][w], focusable); continue; }
        out += tok("t-val", w, prog[3][w] || null, focusable);
      }
      return out;
    }).join("");
    return html + (comment ? tok("t-comment", comment) : "");
  }

  /// JSON: keys explained from JSONKEYS, references explained, everything else coloured.
  function json(text, focusable) {
    return (text.match(/"(?:[^"\\]|\\.)*"(?=\s*:)|"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null|[{}\[\],:]|\s+|[^\s"{}\[\],:]+/g) || []).map(function (w, i, all) {
      if (/^\s+$/.test(w)) return w;
      if (w[0] === '"') {
        var rest = all.slice(i + 1).join("");
        if (/^\s*:/.test(rest)) { var k = w.slice(1, -1); return tok("t-key", w, JSONKEYS[k] || null, focusable); }
        var tip = null; Object.keys(REF).forEach(function (p) { if (!tip && w.slice(1).indexOf(p) === 0) tip = REF[p]; });
        return tok(tip ? "t-ref" : "t-str", w, tip, focusable);
      }
      if (/^[{}\[\],:]$/.test(w)) return tok("t-punct", w);
      return tok("t-val", w);
    }).join("");
  }

  /// Prose with `code` spans (the agent note): commands in backticks are explained, and so are references.
  function prose(line, opts) {
    var focusable = !(opts && opts.inert);
    return line.split(/(`[^`]*`)/).map(function (part) {
      if (part[0] === "`") return tok("t-punct", "`") + shell(part.slice(1, -1), opts) + tok("t-punct", "`");
      return esc(part).replace(/latchkey:\/\//g, function (r) { return tok("t-ref", r, REF["latchkey://"], focusable); });
    }).join("");
  }

  /// Plain text: synopses, sample output, env files and the diagram.
  function textLine(line, opts) {
    var focusable = !(opts && opts.inert);
    if (/[─►├└]/.test(line)) {
      var d = esc(line);
      DIAGRAM.forEach(function (p) { d = d.split(esc(p[0])).join(tok("t-act", p[0], p[1], focusable)); });
      return d;
    }
    if (/^\s*(\$\s+)?(lk|latchkey)(\s|$)/.test(line)) return highlight(line, { inert: opts.inert, synopsis: true });
    if (SHELL[line.trim().split(/\s+/)[0]]) return shell(line, opts);
    if (/^\s*[A-Za-z_][A-Za-z0-9_]*=/.test(line)) return assign(line, focusable);
    var m = line.match(/^(\s*)(agent-safe|granted|asks|missing)(\s.*)$/);
    if (m) return esc(m[1]) + tok("t-act", m[2], CHECK[m[2]], focusable) + esc(m[3]);
    return esc(line);
  }

  // ---- Explain every code block: lk and the programs beside it, env files, JSON, synopses, the agent note and the
  // diagram. The scenes are drawings that type themselves, and the home page's live demos rewrite their own text, so
  // they're left alone. The developer pages explain every option in their tables, so there the explanations come on
  // hover only and the parts don't add stops to the keyboard's path.
  var docs = !!document.querySelector("main.docs");
  document.querySelectorAll("pre").forEach(function (pre) {
    if (pre.closest(".scene-wrap, [aria-hidden='true'], .appwin, .term") || (pre.closest(".scene") && !pre.closest(".lane"))) return;
    var code = pre.querySelector("code") || pre;
    if (code.querySelector("*")) return;
    var text = code.textContent, lang = code.dataset ? code.dataset.lang || "" : "", opts = { inert: docs };
    var trimmed = text.trim();
    if (lang === "json" || (!lang && /^[{\["]/.test(trimmed))) code.innerHTML = json(text, !docs);
    else if (lang === "markdown") code.innerHTML = text.split("\n").map(function (l) { return prose(l, opts); }).join("\n");
    else if (lang === "text") code.innerHTML = text.split("\n").map(function (l) { return textLine(l, opts); }).join("\n");
    else code.innerHTML = text.split("\n").map(function (l) { return shell(l, opts); }).join("\n");
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

  // ---- Keep the last two words of a paragraph, list item, cell or caption together, so none ends with one word on a
  // line of its own. A last word longer than 28 characters may still go alone, rather than push the line wider. Text in
  // a block inside the element (a note under a table cell, a label beside a heading) is its own paragraph.
  var measure = document.createElement("canvas").getContext("2d");
  function ownBlock(node, el) {
    for (var e = node.parentElement; e && e !== el; e = e.parentElement) if (!/^inline/.test(getComputedStyle(e).display)) return false;
    return true;
  }
  document.querySelectorAll("main h1, main h2, main h3, main p, main li, main td, main dd, main figcaption, main summary, main .card > span, main small").forEach(function (el) {
    if (el.closest("pre, .scene-wrap, .appwin, .term, .scene")) return;
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), nodes = [], n;
    while ((n = walker.nextNode())) if (ownBlock(n, el)) nodes.push(n);
    var tail = 0;
    for (var i = nodes.length - 1; i >= 0; i--) {
      var t = nodes[i].data, end = t.length;
      if (!tail) { end = t.replace(/\s+$/, "").length; if (!end) continue; }
      var at = t.lastIndexOf(" ", end - 1);
      if (at < 0 || (!tail && at === end - 1)) { tail += end; if (tail > 28) return; continue; }
      if (tail + (end - at - 1) > 28) return;
      // Two words held together must fit the element's width as laid out now, or they'd widen a narrow column (a
      // table cell on a phone).
      var cs = getComputedStyle(el), pair = t.slice(0, at).match(/\S*$/)[0] + " " + t.slice(at + 1, end) + "x".repeat(tail);
      measure.font = cs.fontWeight + " " + cs.fontSize + " " + cs.fontFamily;
      if (measure.measureText(pair).width > (el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)) * 0.9) return;
      nodes[i].data = t.slice(0, at) + "\u00a0" + t.slice(at + 1);
      return;
    }
  });

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
