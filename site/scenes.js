// Scenes: small drawings of Latchkey in use that play by themselves while they're on screen, then start over.
// Each .scene-wrap[data-scene] names a script below; its HTML is the drawing at its last frame, so a page without
// scripts, or a visitor who prefers reduced motion, sees how the scene ends. Commands and output are what Latchkey
// prints (from Sources/latchkey); project output and values are examples.
(function () {
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var PAUSE = '<svg viewBox="0 0 12 12" aria-hidden="true"><rect x="2" y="1.5" width="2.8" height="9" rx=".8"/><rect x="7.2" y="1.5" width="2.8" height="9" rx=".8"/></svg>';
  var PLAY = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 1.6v8.8a.6.6 0 0 0 .9.5l7-4.4a.6.6 0 0 0 0-1L3.9 1.1a.6.6 0 0 0-.9.5z"/></svg>';
  function Stop() {}

  function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }

  /// The helpers a scene script plays with. Every wait checks that the scene is still meant to be playing, and
  /// throws Stop when it isn't, so a scene scrolled away or paused halts where it is.
  function Player(wrap) {
    var self = this, canvas = wrap.querySelector(".canvas");
    this.wrap = wrap; this.canvas = canvas; this.token = 0; this.instant = reduce;
    this.$ = function (sel) { return canvas.querySelector(sel); };
    this.$$ = function (sel) { return Array.prototype.slice.call(canvas.querySelectorAll(sel)); };
    this.wait = function (ms) {
      var t = self.token;
      return new Promise(function (res, rej) {
        setTimeout(function () { t === self.token ? res() : rej(new Stop()); }, self.instant ? 0 : ms);
      });
    };
    this.on = function (el, cls, yes) { if (typeof el === "string") el = self.$(el); if (el) el.classList.toggle(cls, yes !== false); return el; };
    this.show = function (el) { return self.on(el, "off", false); };
    this.hide = function (el) { return self.on(el, "off", true); };

    // ---- Terminals: a <pre> whose children are lines; the last line can hold a caret.
    this.clear = function (pre) { pre.innerHTML = ""; };
    this.line = function (pre, html) {
      var c = pre.querySelector(".cur"); if (c) c.remove();
      var l = document.createElement("span"); l.className = "l"; l.innerHTML = html || "";
      pre.appendChild(l); return l;
    };
    this.lines = async function (pre, list, gap) {
      for (var i = 0; i < list.length; i++) { self.line(pre, list[i]); await self.wait(gap == null ? 110 : gap); }
    };
    this.prompt = function (pre, where) {
      var l = self.line(pre, '<span class="p">' + esc(where || "~/Projects/shop") + ' $</span> <span class="t"></span><span class="cur"></span>');
      return l;
    };
    this.type = async function (pre, text, where) {
      var l = self.prompt(pre, where), t = l.querySelector(".t");
      if (self.instant) { t.textContent = text; }
      else for (var i = 1; i <= text.length; i++) { t.textContent = text.slice(0, i); await self.wait(text[i - 1] === " " ? 45 : 24); }
      await self.wait(260);
      var c = l.querySelector(".cur"); if (c) c.remove();
      return l;
    };

    // ---- The pointer: moved by transform, pressed with a little squeeze.
    var cursor = canvas.querySelector(".cursor");
    // Moves (the pointer, chips) are often started without waiting for them, so a scene that stops mid-move
    // mustn't leave a rejected promise behind: they end quietly, and the scene's next wait stops it.
    function quietly(p) { return p.catch(function (e) { if (!(e instanceof Stop)) throw e; }); }
    this.point = function (x, y, ms) {
      if (!cursor) return Promise.resolve();
      cursor.style.transitionDuration = self.instant ? "0s" : (ms || 800) + "ms";
      cursor.style.transform = "translate(" + x + "px," + y + "px)";
      return quietly(self.wait(ms || 800));
    };
    this.pointAt = function (el, dx, dy, ms) {
      if (typeof el === "string") el = self.$(el);
      var c = canvas.getBoundingClientRect(), r = el.getBoundingClientRect(), s = c.width / canvas.offsetWidth;
      return self.point((r.left - c.left + r.width / 2) / s + (dx || 0), (r.top - c.top + r.height / 2) / s + (dy || 0), ms);
    };
    this.click = async function (el) {
      if (cursor) { cursor.classList.remove("press"); void cursor.offsetWidth; cursor.classList.add("press"); }
      if (el) self.on(el, "hit");
      await self.wait(240);
      if (el) self.on(el, "hit", false);
    };

    // ---- Chips: something in flight between two points of the canvas.
    this.fly = function (chip, from, to, ms) {
      chip.style.transition = "none";
      chip.style.left = from[0] + "px"; chip.style.top = from[1] + "px";
      void chip.offsetWidth;
      chip.style.transition = "";
      chip.classList.add("on");
      return quietly(self.wait(30).then(function () {
        chip.style.left = to[0] + "px"; chip.style.top = to[1] + "px";
        return self.wait(ms || 720);
      }));
    };
    this.land = function (chip) { chip.classList.remove("on"); };
  }

  var SCENES = {};

  // ---------------------------------------------------------------------------------------------------------------
  // Hero: a reference in an env file, Latchkey asking, the value reaching the command and never its output.
  SCENES.flow = {
    reset: function (s) {
      s.$$(".ln").forEach(function (l) { s.on(l, "hl", false); });
      s.clear(s.$("#flow-tty")); s.prompt(s.$("#flow-tty"));
      var st = s.$("#flow-state"); st.className = "state"; st.querySelector("span").textContent = "Waiting for a command";
      s.$$(".chip").forEach(s.land);
    },
    play: async function (s) {
      var tty = s.$("#flow-tty"), st = s.$("#flow-state"), label = st.querySelector("span");
      s.clear(tty);
      await s.wait(500);
      await s.type(tty, "lk run --env-file .env.local -- npm run dev");
      var lines = s.$$("#flow-env .ln.r"), chips = s.$$("#flow .chip.ref"), vals = s.$$("#flow .chip.val");
      label.textContent = "Reading references";
      for (var i = 0; i < lines.length; i++) {
        s.on(lines[i], "hl");
        s.fly(chips[i], [64 + i * 12, 52 + i * 19], [446, 76 + i * 22], 700);
        await s.wait(240);
      }
      await s.wait(700);
      chips.forEach(s.land);
      st.className = "state ask"; label.textContent = "Approve with Touch ID";
      await s.wait(1500);
      st.className = "state done"; label.textContent = "Released to npm run dev";
      await s.wait(500);
      for (var j = 0; j < vals.length; j++) { s.fly(vals[j], [470, 98], [80 + j * 96, 286], 760); await s.wait(140); }
      await s.wait(800);
      vals.forEach(s.land);
      lines.forEach(function (l) { s.on(l, "hl", false); });
      await s.lines(tty, ['<span class="d">&gt; shop@1.0.0 dev</span>', '<span class="d">&gt; next dev</span>', "",
                          "  ▲ Next.js", "  - Local:   http://localhost:3000", '  <span class="ok">✓ Ready</span>']);
      label.textContent = "Values stay out of the file and the output";
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // 01: a fresh clone has no env file; Latchkey knows the project from its remote and writes one of references.
  SCENES.clone = {
    reset: function (s) { s.clear(s.$("#clone-tty")); s.prompt(s.$("#clone-tty"), "~/Projects"); s.hide("#clone-env"); },
    play: async function (s) {
      var tty = s.$("#clone-tty");
      s.clear(tty);
      await s.wait(400);
      await s.type(tty, "git clone git@github.com:acme/shop.git && cd shop", "~/Projects");
      await s.lines(tty, ['<span class="d">Cloning into \'shop\'...</span>']);
      await s.type(tty, "npm run dev");
      await s.lines(tty, ['<span class="d">&gt; next dev</span>', '<span class="err">Error: DATABASE_URL is not set</span>']);
      await s.wait(900);
      await s.type(tty, "lk project");
      await s.lines(tty, ["remote origin: github.com/acme/shop", "project shop (through origin)", "  shop/development", "  shop/production",
                          '<span class="d">next: lk export shop/development --out .env.local</span>']);
      await s.wait(900);
      await s.type(tty, "lk export shop/development --out .env.local");
      await s.lines(tty, ["wrote .env.local: 3 references, 1 plain setting", '<span class="d">next: lk run --env-file .env.local -- &lt;your command&gt;</span>']);
      s.show("#clone-env");
      await s.wait(1400);
      await s.type(tty, "lk run --env-file .env.local -- npm run dev");
      await s.lines(tty, ['<span class="d">&gt; next dev</span>', '  <span class="ok">✓ Ready</span> on http://localhost:3000']);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // 02: import an env file. The dry run first, then the real thing; values become references, settings stay.
  SCENES.importenv = {
    reset: function (s) {
      s.clear(s.$("#imp-tty")); s.prompt(s.$("#imp-tty"));
      s.$$("#imp-env .ln").forEach(function (l) {
        var v = l.querySelector(".v"); if (!v) return;
        v.textContent = v.dataset.before; v.className = "v lit"; s.on(l, "hl", false);
      });
      s.hide("#imp-touch"); s.on("#imp-touch", "ok", false);
    },
    play: async function (s) {
      var tty = s.$("#imp-tty");
      s.clear(tty);
      await s.wait(600);
      await s.type(tty, "lk import .env.local --dry-run --skip PORT");
      await s.lines(tty, ["into project shop, environment development",
                          '<span class="d">ignore   PORT  (skipped: expires, or excluded by --skip)</span>',
                          "add      shop/development/DATABASE_URL  password",
                          "add      shop/development/OPENAI_API_KEY  token",
                          "add      shop/development/STRIPE_KEY  token"], 140);
      await s.wait(1300);
      await s.type(tty, "lk import .env.local --rewrite --skip PORT");
      s.show("#imp-touch");
      await s.wait(1300);
      s.on("#imp-touch", "ok");
      await s.wait(500);
      s.hide("#imp-touch");
      await s.lines(tty, ["recorded shop/development: DATABASE_URL, OPENAI_API_KEY, STRIPE_KEY",
                          "added    shop/development/DATABASE_URL  password",
                          "added    shop/development/OPENAI_API_KEY  token",
                          "added    shop/development/STRIPE_KEY  token"], 120);
      var vs = s.$$("#imp-env .v[data-after]");
      for (var i = 0; i < vs.length; i++) {
        var l = vs[i].closest(".ln");
        s.on(l, "hl");
        await s.wait(220);
        vs[i].textContent = vs[i].dataset.after; vs[i].className = "v ref";
        await s.wait(260);
        s.on(l, "hl", false);
      }
      await s.lines(tty, ["rewrote .env.local: 3 values now latchkey://ID", '<span class="d">next: lk run --env-file .env.local -- &lt;your command&gt;</span>']);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // 03: one Mac saves, iCloud Keychain carries the items and the environment record, the other Mac rebuilds.
  SCENES.macs = {
    reset: function (s) {
      s.$$("#macs-a .row.added").forEach(function (r) { r.classList.add("off"); r.style.display = "none"; });
      s.on("#macs-arc", "on", false);
      s.clear(s.$("#macs-tty")); s.prompt(s.$("#macs-tty"), "~/Code");
    },
    play: async function (s) {
      var tty = s.$("#macs-tty");
      s.clear(tty); s.prompt(tty, "~/Code");
      await s.wait(500);
      var rows = s.$$("#macs-a .row.added");
      for (var i = 0; i < rows.length; i++) { rows[i].style.display = ""; rows[i].classList.remove("off"); rows[i].classList.add("new"); await s.wait(260); }
      await s.wait(400);
      s.on("#macs-arc", "on");
      await s.wait(1600);
      s.on("#macs-arc", "on", false);
      s.clear(tty);
      await s.type(tty, "git clone git@github.com:acme/shop.git && cd shop", "~/Code");
      await s.type(tty, "lk project", "~/Code/shop");
      await s.lines(tty, ["remote origin: github.com/acme/shop", "project shop (through origin)", "  shop/development",
                          '<span class="d">next: lk export shop/development --out .env.local</span>']);
      await s.type(tty, "lk export shop/development --out .env.local", "~/Code/shop");
      await s.lines(tty, ["wrote .env.local: 3 references, 1 plain setting"]);
      await s.type(tty, "lk run --env-file .env.local -- npm test", "~/Code/shop");
      await s.lines(tty, ['<span class="d"> Test Files  2 passed (2)</span>']);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // 04: an agent's command asks; the person allows the folder until the agent quits; the next run goes through;
  // a production item isn't covered and is refused.
  SCENES.agent = {
    reset: function (s) {
      s.clear(s.$("#agent-tty")); s.prompt(s.$("#agent-tty"));
      s.hide("#agent-panel"); s.hide("#agent-note"); s.on("#agent-grant", "on", false); s.on("#agent-only", "dim", true);
      s.$("#agent-allow").textContent = "Allow Once";
      s.$("#agent-title").textContent = "Claude wants to use 2 items";
      s.$("#agent-items").textContent = "shop/development/DATABASE_URL, shop/development/STRIPE_KEY";
      s.$("#agent-cmd").textContent = "lk run --env shop/development -- npm test";
      s.$("#agent-only span").textContent = "Only for npm test";
      s.point(470, 300, 1);
    },
    play: async function (s) {
      var tty = s.$("#agent-tty");
      s.clear(tty);
      await s.wait(500);
      s.line(tty, '<span class="k">⏺ Claude</span> <span class="d">I\'ll run the tests with Latchkey.</span>');
      await s.wait(500);
      await s.type(tty, "lk run --env shop/development -- npm test");
      s.show("#agent-panel");
      await s.wait(700);
      await s.pointAt("#agent-grant i", 0, 4);
      await s.click();
      s.on("#agent-grant", "on"); s.on("#agent-only", "dim", false);
      s.$("#agent-allow").textContent = "Allow from Folder";
      await s.wait(500);
      await s.pointAt("#agent-allow", 0, 4, 600);
      await s.click(s.$("#agent-allow"));
      await s.wait(300);
      s.hide("#agent-panel");
      await s.point(470, 300, 700);
      await s.lines(tty, ['<span class="d"> ✓ db/connect.test.ts (3 tests)</span>', '   connecting to <span class="c">&lt;concealed by latchkey&gt;</span>',
                          '<span class="d"> Test Files  2 passed (2)</span>']);
      await s.wait(900);
      await s.type(tty, "lk run --env shop/development -- npm test -- --watch=false");
      s.show("#agent-note");
      await s.lines(tty, ['<span class="d"> Test Files  2 passed (2)</span>']);
      await s.wait(1400);
      s.hide("#agent-note");
      await s.type(tty, "lk run --env shop/production -- npm run migrate");
      s.$("#agent-title").textContent = "Claude wants to use shop/production/DATABASE_URL";
      s.$("#agent-items").textContent = "shop/production/DATABASE_URL";
      s.$("#agent-cmd").textContent = "lk run --env shop/production -- npm run migrate";
      s.$("#agent-only span").textContent = "Only for npm run migrate";
      s.on("#agent-grant", "on", false); s.on("#agent-only", "dim", true); s.$("#agent-allow").textContent = "Allow Once";
      s.show("#agent-panel");
      await s.wait(900);
      await s.pointAt("#agent-deny", 0, 4, 700);
      await s.click(s.$("#agent-deny"));
      s.hide("#agent-panel");
      await s.point(470, 300, 600);
      await s.lines(tty, ['<span class="err">latchkey: refused: shop/production/DATABASE_URL (not agent-safe, not approved, no grant)</span>',
                          '<span class="k">⏺ Claude</span> <span class="d">Latchkey refused that (exit 77), so I\'ll stop and ask you.</span>'], 220);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Rotation: what the agent was given, a new value saved, and the env file's reference left as it was.
  SCENES.rotate = {
    reset: function (s) {
      s.clear(s.$("#rot-tty")); s.prompt(s.$("#rot-tty"));
      s.on("#rot-ref", "hl", false); s.on("#rot-ver", "hl", false); s.$("#rot-ver").textContent = "1 earlier value";
    },
    play: async function (s) {
      var tty = s.$("#rot-tty");
      s.clear(tty);
      await s.wait(500);
      await s.type(tty, "lk touched --since 4h --by claude");
      await s.lines(tty, ["shop/development/DATABASE_URL  4×, last Nov 11, 2026 at 3:12 PM  (zsh › claude › Terminal)",
                          "shop/development/STRIPE_KEY  2×, last Nov 11, 2026 at 3:12 PM  (zsh › claude › Terminal)", "",
                          '<span class="d">Replace them with: latchkey rotate --touched --by claude</span>']);
      await s.wait(1000);
      await s.type(tty, "lk rotate shop/development/STRIPE_KEY --open");
      await s.lines(tty, ["ended grant 7c41e9 (shop/development/*)", "",
                          "[1/1] shop/development/STRIPE_KEY  (Stripe)",
                          "  Make a new key at https://dashboard.stripe.com/apikeys, then revoke the old one there.",
                          "  New value (leave empty to skip): ••••••••"], 160);
      await s.wait(700);
      await s.lines(tty, ['  <span class="ok">saved; the old value is in its history</span>']);
      s.$("#rot-ver").textContent = "2 earlier values"; s.on("#rot-ver", "hl");
      s.on("#rot-ref", "hl");
      await s.wait(1600);
      s.on("#rot-ref", "hl", false);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Latchkey for Safari: a new key on the page where it was made, saved to a project's environment.
  SCENES.safari = {
    reset: function (s) { s.hide("#saf-save"); s.hide("#saf-touch"); s.on("#saf-touch", "ok", false); s.hide("#saf-done"); s.point(420, 240, 1); },
    play: async function (s) {
      await s.wait(700);
      await s.pointAt("#saf-btn", 0, 3);
      await s.click(s.$("#saf-btn"));
      s.show("#saf-save");
      await s.wait(900);
      await s.pointAt("#saf-go", 0, 3, 600);
      await s.click(s.$("#saf-go"));
      s.hide("#saf-save");
      s.show("#saf-touch");
      await s.wait(1200);
      s.on("#saf-touch", "ok");
      await s.wait(500);
      s.hide("#saf-touch");
      s.show("#saf-done");
      await s.point(420, 240, 700);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // The access log: every release, with who asked and from where, chained so an edit shows.
  SCENES.log = {
    reset: function (s) { s.clear(s.$("#log-tty")); s.prompt(s.$("#log-tty")); },
    play: async function (s) {
      var tty = s.$("#log-tty");
      s.clear(tty);
      await s.wait(500);
      await s.type(tty, "lk history shop/development/STRIPE_KEY");
      await s.lines(tty, ["1   Nov 11, 2026 at 3:20 PM  replaced  by zsh › Terminal",
                          '<span class="d">Kept: the last 10 per item. `latchkey restore shop/development/STRIPE_KEY --version N` puts one back.</span>']);
      await s.wait(900);
      await s.type(tty, "lk log --verify");
      await s.lines(tty, ['<span class="ok">intact: 412 signed entries</span>']);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Security: a committed reference shows only a name; a script that asks Latchkey directly, not through the signed
  // lk tool, gets the panel with its warning, and is denied.
  SCENES.direct = {
    reset: function (s) { s.clear(s.$("#dir-tty")); s.prompt(s.$("#dir-tty")); s.hide("#dir-panel"); s.hide("#dir-note"); s.point(480, 300, 1); },
    play: async function (s) {
      var tty = s.$("#dir-tty");
      s.clear(tty);
      await s.wait(500);
      await s.type(tty, "git show HEAD:.env.local");
      await s.lines(tty, ["DATABASE_URL=latchkey://shop/development/DATABASE_URL", "STRIPE_KEY=latchkey://shop/development/STRIPE_KEY"]);
      s.show("#dir-note");
      await s.wait(1800);
      s.hide("#dir-note");
      await s.type(tty, "node scripts/sync.js");
      s.show("#dir-panel");
      await s.wait(1600);
      await s.pointAt("#dir-deny", 0, 4, 700);
      await s.click(s.$("#dir-deny"));
      s.hide("#dir-panel");
      await s.point(480, 300, 600);
      await s.lines(tty, ['<span class="err">refused: shop/development/STRIPE_KEY (not agent-safe, not approved, no grant)</span>']);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Teams: an inventory of every env file under a folder, before anything is sent: where each goes, the value every
  // project shares, what expires, and two files that disagree. Then the import.
  SCENES.inventory = {
    reset: function (s) { s.clear(s.$("#inv-tty")); s.prompt(s.$("#inv-tty"), "~"); },
    play: async function (s) {
      var tty = s.$("#inv-tty");
      s.clear(tty);
      await s.wait(500);
      await s.type(tty, "lk import --scan ~/Projects --share-identical --dry-run", "~");
      await s.lines(tty, ["~/Projects/api/.env  →  api/development: 3 to import, 1 shared, 1 in conflict",
                          "~/Projects/api/.env.local  →  api/development: 4 to import, 1 shared, 1 in conflict",
                          "~/Projects/blog/.env  →  blog/development: 2 to import, 1 shared",
                          "~/Projects/shop/.env.local  →  shop/development: 4 to import, 1 shared, 1 skipped", "",
                          "10 items from 4 files: 10 new, 0 already exist",
                          '<span class="ok">shared (same value everywhere): OPENAI_API_KEY ×4</span>',
                          '<span class="d">skipped: VERCEL_OIDC_TOKEN</span>',
                          '<span class="w">conflict: api/development/DATABASE_URL differs between ~/Projects/api/.env and ~/Projects/api/.env.local; not imported</span>',
                          "Nothing sent."], 160);
      await s.wait(1800);
      await s.type(tty, "lk import --scan ~/Projects --share-identical --rewrite", "~");
      await s.lines(tty, ["recorded api/development, blog/development, shop/development", "imported 10 new",
                          "rewrote ~/Projects/api/.env: 3 now latchkey://ID",
                          "rewrote ~/Projects/api/.env.local: 4 now latchkey://ID",
                          "rewrote ~/Projects/blog/.env: 2 now latchkey://ID",
                          "rewrote ~/Projects/shop/.env.local: 4 now latchkey://ID"], 140);
    }
  };

  // ---------------------------------------------------------------------------------------------------------------
  function attach(wrap) {
    var script = SCENES[wrap.dataset.scene];
    if (!script) return;
    var p = new Player(wrap), canvas = p.canvas, w = +getComputedStyle(wrap).getPropertyValue("--w");
    function fit() { canvas.style.setProperty("--s", wrap.clientWidth / w); }
    fit();
    if ("ResizeObserver" in window) new ResizeObserver(fit).observe(wrap); else window.addEventListener("resize", fit);
    if (reduce) return;   // the last frame, as written in the HTML

    var btn = document.createElement("button");
    btn.type = "button"; btn.className = "scene-pause"; btn.innerHTML = PAUSE; btn.setAttribute("aria-label", "Pause this animation");
    wrap.appendChild(btn);
    var visible = false, paused = false, playing = false;
    async function loop() {
      if (playing) return;
      playing = true;
      while (visible && !paused) {
        try { script.reset(p); await p.wait(200); await script.play(p); await p.wait(3200); }
        catch (e) { if (!(e instanceof Stop)) { playing = false; throw e; } break; }
      }
      playing = false;
    }
    function stop() { p.token++; }
    btn.addEventListener("click", function () {
      paused = !paused;
      wrap.classList.toggle("paused", paused);
      btn.innerHTML = paused ? PLAY : PAUSE;
      btn.setAttribute("aria-label", paused ? "Play this animation" : "Pause this animation");
      if (paused) stop(); else loop();
    });
    var io = new IntersectionObserver(function (es) {
      var now = es[0].isIntersecting;
      if (now === visible) return;
      visible = now;
      if (visible) loop(); else stop();
    }, { threshold: 0.35 });
    io.observe(wrap);
  }
  document.querySelectorAll(".scene-wrap[data-scene]").forEach(attach);
})();
