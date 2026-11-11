// Latchkey's secret detector: finds keys, tokens, private keys and connection strings in text, and says how sure it
// is. It runs only in the page; nothing it finds leaves the page unless you press Save. The provider rules are
// adapted for the browser from the kind of rules secret scanners such as Gitleaks use; randomness on its own is
// never enough, only supporting evidence.
(function (root) {
  "use strict";

  // Formats that identify the issuer. name: the item name to suggest. env: what the key says about its environment.
  var RULES = [
    { id: "stripe-secret", re: /\bsk_(live|test)_[A-Za-z0-9]{24,}(?![A-Za-z0-9_-])/, service: "Stripe", type: "Stripe secret key", name: "STRIPE_SECRET_KEY", env: true },
    { id: "stripe-restricted", re: /\brk_(live|test)_[A-Za-z0-9]{24,}(?![A-Za-z0-9_-])/, service: "Stripe", type: "Stripe restricted key", name: "STRIPE_RESTRICTED_KEY", env: true },
    { id: "stripe-webhook", re: /\bwhsec_[A-Za-z0-9]{24,}(?![A-Za-z0-9_-])/, service: "Stripe", type: "Stripe webhook secret", name: "STRIPE_WEBHOOK_SECRET" },
    { id: "anthropic", re: /\bsk-ant-[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])/, service: "Anthropic", type: "Anthropic API key", name: "ANTHROPIC_API_KEY" },
    { id: "openai", re: /\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])/, service: "OpenAI", type: "OpenAI API key", name: "OPENAI_API_KEY" },
    { id: "github-pat", re: /\bgithub_pat_[A-Za-z0-9_]{50,}(?![A-Za-z0-9_-])/, service: "GitHub", type: "GitHub token", name: "GITHUB_TOKEN" },
    { id: "github-token", re: /\bgh[pousr]_[A-Za-z0-9]{36,}(?![A-Za-z0-9_-])/, service: "GitHub", type: "GitHub token", name: "GITHUB_TOKEN" },
    { id: "gitlab", re: /\bglpat-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])/, service: "GitLab", type: "GitLab token", name: "GITLAB_TOKEN" },
    { id: "slack-bot", re: /\bxoxb-[0-9]{8,}-[0-9]{8,}-[A-Za-z0-9]{20,}(?![A-Za-z0-9_-])/, service: "Slack", type: "Slack bot token", name: "SLACK_BOT_TOKEN" },
    { id: "slack-user", re: /\bxoxp-[0-9]{8,}-[0-9]{8,}-[0-9]{8,}-[a-f0-9]{24,}(?![A-Za-z0-9_-])/, service: "Slack", type: "Slack user token", name: "SLACK_USER_TOKEN" },
    { id: "slack-app", re: /\bxapp-[0-9]-[A-Z0-9]{8,}-[0-9]{8,}-[a-f0-9]{32,}(?![A-Za-z0-9_-])/, service: "Slack", type: "Slack app token", name: "SLACK_APP_TOKEN" },
    { id: "aws-key-id", re: /\b(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9_-])/, service: "AWS", type: "AWS access key ID", name: "AWS_ACCESS_KEY_ID", weak: true },
    { id: "google-api", re: /\bAIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])/, service: "Google", type: "Google API key", name: "GOOGLE_API_KEY" },
    { id: "sendgrid", re: /\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/, service: "SendGrid", type: "SendGrid API key", name: "SENDGRID_API_KEY" },
    { id: "resend", re: /\bre_[A-Za-z0-9]{8,}_[A-Za-z0-9]{16,}(?![A-Za-z0-9_-])/, service: "Resend", type: "Resend API key", name: "RESEND_API_KEY" },
    { id: "npm", re: /\bnpm_[A-Za-z0-9]{36}(?![A-Za-z0-9_-])/, service: "npm", type: "npm token", name: "NPM_TOKEN" },
    { id: "digitalocean", re: /\bdo[pro]_v1_[a-f0-9]{64}(?![A-Za-z0-9_-])/, service: "DigitalOcean", type: "DigitalOcean token", name: "DIGITALOCEAN_TOKEN" },
    { id: "linear", re: /\blin_api_[A-Za-z0-9]{40}(?![A-Za-z0-9_-])/, service: "Linear", type: "Linear API key", name: "LINEAR_API_KEY" },
    { id: "posthog-personal", re: /\bphx_[A-Za-z0-9]{40,}(?![A-Za-z0-9_-])/, service: "PostHog", type: "PostHog personal API key", name: "POSTHOG_PERSONAL_API_KEY" },
    { id: "huggingface", re: /\bhf_[A-Za-z0-9]{34,}(?![A-Za-z0-9_-])/, service: "Hugging Face", type: "Hugging Face token", name: "HF_TOKEN" },
    { id: "supabase-token", re: /\bsbp_[a-f0-9]{40}(?![A-Za-z0-9_-])/, service: "Supabase", type: "Supabase access token", name: "SUPABASE_ACCESS_TOKEN" },
    { id: "fly", re: /\b(?:fo1_[A-Za-z0-9_-]{40,}|FlyV1 fm[12]_[A-Za-z0-9+/=_,-]{40,})/, service: "Fly", type: "Fly token", name: "FLY_API_TOKEN" },
    { id: "twilio-key", re: /\bSK[0-9a-f]{32}(?![A-Za-z0-9_-])/, service: "Twilio", type: "Twilio API key", name: "TWILIO_API_KEY", weak: true }
  ];

  // Keys that are public by design, and so not worth saving as secrets.
  var PUBLIC = [/\bpk_(?:live|test)_[A-Za-z0-9]{24,}\b/, /\bphc_[A-Za-z0-9]{30,}\b/];

  var PEM_PRIVATE = /-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----[\s\S]+?-----END (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/;
  var PEM_CERT = /-----BEGIN CERTIFICATE-----/;
  // A URL with a password in it: user:password@host.
  var CONNECTION = /\b(postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqps?):\/\/[^\s:@/]*:([^\s@/]{6,})@[^\s/]+[^\s"'<>]*/;
  var JWT = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{16,}\b/;
  var GENERIC = /[A-Za-z0-9_\-+/=]{32,}/g;

  // Words around a field that say it holds a secret, and words that say a key is being shown once.
  var SECRET_WORDS = /\b(api[ _-]?key|secret|access[ _-]?key|access[ _-]?token|auth(?:entication)?[ _-]?token|bearer|private[ _-]?key|client[ _-]?secret|signing[ _-]?(?:key|secret)|webhook[ _-]?secret|password|connection[ _-]?string|personal[ _-]?access[ _-]?token|service[ _-]?(?:role[ _-]?)?key|token)\b/i;
  var ONCE_WORDS = /(won.?t be able to see it again|shown only once|only be shown once|only see (?:it|this) once|copy (?:it|this|your) (?:now|key|token)|store (?:it|this) (?:somewhere )?safe|keep (?:it|your key|this key) safe|you won.?t see|will not be shown again|make sure to copy)/i;
  // Values that are shown hidden, or are obviously examples.
  var MASKED = /[•●*…]|\.{3}|x{6,}|X{6,}/;
  var EXAMPLE = /(example|sample|placeholder|dummy|your[_-]?(?:api[_-]?)?(?:key|token|secret)|<[^>]*>|\$\{|\{\{|REPLACE|CHANGEME|EXAMPLEKEY|AKIAIOSFODNN7EXAMPLE)/i;

  function entropy(s) {
    var counts = {}, n = s.length, h = 0;
    for (var i = 0; i < n; i++) counts[s[i]] = (counts[s[i]] || 0) + 1;
    for (var k in counts) { var p = counts[k] / n; h -= p * Math.log2(p); }
    return h;
  }

  function snake(label) {
    var words = (label || "").replace(/[^A-Za-z0-9 ]+/g, " ").trim().split(/\s+/).slice(0, 4);
    var name = words.join("_").toUpperCase();
    return /^[A-Z][A-Z0-9_]{2,40}$/.test(name) ? name : null;
  }

  /// What a value is, how sure we are (0 to 1), and how to save it. `context`: { label, nearby, host, field }.
  /// label: the field's own label or name; nearby: text around it (a dialog, a heading); host: the page's host;
  /// field: true when the value sits in its own input, textarea or code block. Returns null for nothing worth saving.
  function classify(value, context) {
    context = context || {};
    var v = (value || "").trim();
    if (v.length < 16 || v.length > 16384) return null;
    if (MASKED.test(v) || EXAMPLE.test(v)) return null;
    if (/^(.)\1+$/.test(v)) return null;
    if (PEM_CERT.test(v) && !PEM_PRIVATE.test(v)) return null;   // a certificate is public; its private key isn't
    for (var p = 0; p < PUBLIC.length; p++) { var pm = v.match(PUBLIC[p]); if (pm && pm[0].length >= v.length - 2) return null; }

    var label = context.label || "", nearby = context.nearby || "", host = (context.host || "").toLowerCase();
    var secretContext = SECRET_WORDS.test(label) || SECRET_WORDS.test(nearby.slice(0, 400));
    var once = ONCE_WORDS.test(nearby);
    var bonus = (secretContext ? 0.1 : 0) + (once ? 0.15 : 0) + (context.field ? 0.05 : 0);
    var result = null;

    var pem = v.match(PEM_PRIVATE);
    if (pem) {
      result = { value: pem[0], type: "Private key", service: "", name: snake(label) || "PRIVATE_KEY", kind: "key", score: 0.95 };
    }
    if (!result) {
      var conn = v.match(CONNECTION);
      if (conn && !EXAMPLE.test(conn[2]) && conn[2] !== "password") {
        var scheme = conn[1].toLowerCase();
        var name = /^mongo/.test(scheme) ? "MONGODB_URI" : /^redis/.test(scheme) ? "REDIS_URL" : /^amqp/.test(scheme) ? "AMQP_URL" : "DATABASE_URL";
        result = { value: conn[0], type: "Connection string with a password", service: "", name: name, kind: "password", score: 0.85 };
      }
    }
    if (!result) {
      for (var i = 0; i < RULES.length; i++) {
        var r = RULES[i], m = v.match(r.re);
        if (!m) continue;
        // Some formats are too short or common to trust alone: they need the page to say it's a key.
        var score = r.weak ? (secretContext || once ? 0.75 : 0.4) : 0.85;
        var service = r.service;
        // Clerk's secret keys share Stripe's prefix: the page tells them apart.
        if (r.id === "stripe-secret" && /clerk/.test(host)) { service = "Clerk"; r = { name: "CLERK_SECRET_KEY", type: "Clerk secret key" }; }
        result = { value: m[0], type: r.type, service: service, name: r.name, kind: "token", score: score,
                   environment: m[1] === "live" ? "production" : m[1] === "test" ? "development" : undefined };
        break;
      }
    }
    if (!result) {
      var jwt = v.match(JWT);
      if (jwt) {
        // JWTs are often public (a Supabase anon key, a session that expires). Only a secret-sounding field counts.
        result = { value: jwt[0], type: "Token (JWT)", service: "", name: snake(label) || "API_TOKEN", kind: "token", score: secretContext ? 0.6 : 0.3 };
      }
    }
    if (!result) {
      // A long random-looking string is only a candidate when the page says it's a secret.
      GENERIC.lastIndex = 0;
      var g, best = null;
      while ((g = GENERIC.exec(v))) {
        var s = g[0];
        if (s.length < 32 || s.length > 512) continue;
        if (/^[a-f0-9]{40}$/i.test(s) || /^[a-f0-9]{64}$/i.test(s)) { if (!secretContext) continue; }   // commit and content hashes
        if (/^[A-Za-z]+$/.test(s) || /^[0-9]+$/.test(s)) continue;
        if (/\//.test(s) && !/=$/.test(s) && /\.[a-z]{2,4}(\/|$)/.test(s)) continue;   // a path or URL
        var h = entropy(s);
        if (h < 3.5) continue;
        if (!best || s.length > best.length) best = s;
      }
      if (best && secretContext) {
        var named = snake(label);
        if (/secret access key/i.test(label + " " + nearby.slice(0, 200)) && best.length === 40) named = "AWS_SECRET_ACCESS_KEY";
        result = { value: best, type: "Secret", service: "", name: named || "API_KEY", kind: "token", score: 0.5 };
      }
    }
    if (!result) return null;
    result.score = Math.min(1, result.score + bonus);
    result.confidence = result.score >= 0.75 ? "high" : result.score >= 0.5 ? "medium" : "low";
    return result.confidence === "low" ? null : result;
  }

  /// Every distinct secret in a block of text (several keys can share one code block).
  function findAll(text, context) {
    var found = [], seen = {};
    var pieces = [text];
    // Split long text into lines so one value doesn't hide another; private keys stay whole.
    if (text.length > 120 && !PEM_PRIVATE.test(text)) pieces = text.split(/\s*\n\s*|\s{2,}|[;,"'`]/);
    for (var i = 0; i < pieces.length; i++) {
      var piece = pieces[i];
      if (!piece || piece.length < 16) continue;
      // KEY=value and "key": "value" put the label right next to the value.
      var kv = piece.match(/^\s*([A-Za-z_][A-Za-z0-9_.-]{1,60})\s*[:=]\s*(.+)$/);
      var ctx = kv ? Object.assign({}, context, { label: kv[1] + " " + (context.label || "") }) : context;
      var r = classify(kv ? kv[2] : piece, ctx);
      if (r && !seen[r.value]) { seen[r.value] = true; found.push(r); }
    }
    return found;
  }

  function preview(v) {
    if (/^-----BEGIN/.test(v)) return v.split("\n")[0];
    var cut = v.search(/[_-][A-Za-z0-9]/);
    var head = cut > 0 && cut < 12 ? v.slice(0, cut + 1) : v.slice(0, 6);
    return head + "…" + v.slice(-4);
  }

  var api = { classify: classify, findAll: findAll, preview: preview, entropy: entropy, rules: RULES };
  root.LatchkeyDetector = api;
  if (typeof module !== "undefined") module.exports = api;
})(typeof window !== "undefined" ? window : globalThis);
