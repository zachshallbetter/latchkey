// Pistachio's secret detector: finds keys, tokens, private keys and connection strings in text, and says how sure it
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
  var PEM_CERT = /-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/;
  var PEM_PUBLIC = /-----BEGIN (?:RSA )?PUBLIC KEY-----[\s\S]+?-----END (?:RSA )?PUBLIC KEY-----/;
  var SSH_PUBLIC = /^(?:ssh-(?:rsa|ed25519)|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/=]{24,}(?: [^\r\n]*)?$/;
  var PEM_ANY = /-----BEGIN [A-Z ]+-----/;
  // A URL with a password in it: user:password@host.
  var CONNECTION = /\b(postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqps?):\/\/[^\s:@/]*:([^\s@/]{6,})@[^\s/]+[^\s"'<>]*/;
  var JWT = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{16,}\b/;
  var GENERIC = /[A-Za-z0-9_.~+/-]{24,}={0,2}/g;

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

  function words(text) {
    return String(text || "").slice(0, 1500).replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/[_.-]+/g, " ");
  }
  function snake(label) {
    var name = words(label).replace(/[^A-Za-z0-9 ]+/g, " ").trim().split(/\s+/).slice(0, 6).join("_").toUpperCase();
    return /^[A-Z][A-Z0-9_]{2,63}$/.test(name) ? name : null;
  }

  // Hints only: exact dashboard hosts, never a fill permission or proof of who issued a key.
  var PROVIDERS = [
    ["aistudio.google.com", "Google", "GEMINI"], ["console.cloud.google.com", "Google", "GOOGLE"],
    ["dashboard.stripe.com", "Stripe", "STRIPE"], ["github.com", "GitHub", "GITHUB"],
    ["platform.openai.com", "OpenAI", "OPENAI"], ["console.anthropic.com", "Anthropic", "ANTHROPIC"],
    ["vercel.com", "Vercel", "VERCEL"], ["resend.com", "Resend", "RESEND"],
    ["console.neon.tech", "Neon", "NEON"], ["railway.com", "Railway", "RAILWAY"],
    ["sentry.io", "Sentry", "SENTRY"], ["dash.cloudflare.com", "Cloudflare", "CLOUDFLARE"],
    ["console.aws.amazon.com", "AWS", "AWS"], ["supabase.com", "Supabase", "SUPABASE"],
    ["dashboard.clerk.com", "Clerk", "CLERK"], ["api.slack.com", "Slack", "SLACK"], ["fly.io", "Fly", "FLY"]
  ];
  var NON_SECRET = /\b(public|publishable|anonymous|anon|client id|key id|request id|trace id|session id|resource id|project id|asset id|commit|checksum|fingerprint|sha ?(?:1|256|512)|hash|integrity|nonce|csrf|verification|one time code|otp)\b/i;
  var SAMPLE_CONTEXT = /\b(?:(?:example|sample|dummy|placeholder|demo) (?:api )?(?:key|token|secret|credential)|for illustration|do not use this)\b/i;
  var CREATE_WORDS = /\b(?:new (?:api )?(?:key|token|secret)|(?:create|created|generate|generated|reveal|copy) (?:an? |your |new |this )?(?:api )?(?:key|token|secret)|key details|token details)\b/i;
  function providerFor(context) {
    var label = words(context.variable || context.label).toUpperCase();
    for (var i = 0; i < PROVIDERS.length; i++) {
      var prefix = PROVIDERS[i][2].replace("OPENAI", "OPEN ?AI").replace("GITHUB", "GIT ?HUB");
      if (new RegExp("\\b" + prefix + "\\b").test(label)) return PROVIDERS[i];
    }
    var host = String(context.host || "").toLowerCase().replace(/\.$/, "");
    return PROVIDERS.find(function (p) { return host === p[0]; }) || null;
  }
  function roleName(label) {
    var text = words(label);
    var roles = [
      [/secret access key/i, "SECRET_ACCESS_KEY"], [/webhook secret/i, "WEBHOOK_SECRET"],
      [/client secret/i, "CLIENT_SECRET"], [/signing (?:key|secret)/i, "SIGNING_KEY"],
      [/private key/i, "PRIVATE_KEY"], [/restricted key/i, "RESTRICTED_KEY"],
      [/service role key/i, "SERVICE_ROLE_KEY"], [/secret key/i, "SECRET_KEY"],
      [/api key|access key/i, "API_KEY"], [/token|bearer/i, "TOKEN"], [/password/i, "PASSWORD"], [/secret/i, "SECRET"]
    ];
    var role = roles.find(function (r) { return r[0].test(text); });
    return role ? role[1] : "API_KEY";
  }
  function suggestedName(context, provider) {
    var label = String(context.variable || context.label || "").trim();
    // Keep an explicit credential variable instead of deriving names from arbitrary neighboring prose.
    if (/^[A-Z_][A-Z0-9_]{2,63}$/.test(label) && SECRET_WORDS.test(words(label))) return label;
    if (/^[A-Za-z][A-Za-z0-9_]*$/.test(label) && SECRET_WORDS.test(words(label))) return snake(label);
    var role = roleName(label || context.nearby);
    if (role === "SECRET_ACCESS_KEY") return "AWS_SECRET_ACCESS_KEY";
    return provider ? provider[2] + "_" + role : role;
  }
  function localEnvironment(label) {
    var text = words(label);
    var live = /\b(live|production|prod)\b/i.test(text), test = /\b(test|development|dev|sandbox)\b/i.test(text);
    return live === test ? undefined : live ? "production" : "development";
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
    // A certificate is public (its private key isn't): offered as a plain item, never marked on the page.
    if (PEM_CERT.test(v) && !PEM_PRIVATE.test(v)) {
      return { value: v.match(PEM_CERT)[0], type: "Certificate (public)", service: "", name: snake(context.label) || "CERTIFICATE",
               kind: "value", score: 0.55, confidence: "medium", shownOnce: false, isPublic: true };
    }
    var publicKey = v.match(PEM_PUBLIC) || v.match(SSH_PUBLIC);
    if (publicKey && !PEM_PRIVATE.test(v)) {
      return { value: publicKey[0], type: "Public key", service: "", name: "PUBLIC_KEY", kind: "value",
               score: 0.55, confidence: "medium", shownOnce: false, isPublic: true };
    }
    for (var p = 0; p < PUBLIC.length; p++) { var pm = v.match(PUBLIC[p]); if (pm && pm[0].length >= v.length - 2) return null; }

    var label = words(context.label), nearby = words(context.nearby), host = String(context.host || "").toLowerCase();
    var ownSecret = SECRET_WORDS.test(label), nearbySecret = SECRET_WORDS.test(nearby.slice(0, 400));
    var secretContext = ownSecret || nearbySecret;
    var once = ONCE_WORDS.test(nearby);
    var provider = providerFor(context);
    var creation = once || CREATE_WORDS.test(nearby) || CREATE_WORDS.test(words(context.title));
    var docs = /\b(documentation|tutorial|example|sample)\b/i.test(words(context.title) + " " + words(context.path));
    var awsAccessID = /\baccess key id\b/i.test(label) && /^(?:AKIA|ASIA)[A-Z0-9]{16}$/.test(v);
    if ((NON_SECRET.test(label) && !awsAccessID) || SAMPLE_CONTEXT.test(label) || SAMPLE_CONTEXT.test(nearby)) return null;
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
        if (r.id === "stripe-secret" && provider && provider[1] === "Clerk") { service = "Clerk"; r = { name: "CLERK_SECRET_KEY", type: "Clerk secret key" }; }
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
    if (!result && !/\bhttps?:\/\//i.test(v)) {
      // Context cannot make arbitrary page IDs into secrets. A local label is stronger than page-wide wording.
      var eligible = !/\b(path|filename|file name)\b/i.test(label) && (ownSecret || (nearbySecret && creation && context.field));
      GENERIC.lastIndex = 0;
      var g, best = null;
      while (eligible && (g = GENERIC.exec(v))) {
        var candidate = g[0];
        if (candidate.length < 24 || candidate.length > 512) continue;
        if (/^[0-9]+$/.test(candidate) || entropy(candidate) < 3.5) continue;
        if (/^[A-Za-z]+$/.test(candidate) && !(ownSecret && (provider || creation) && entropy(candidate) >= 4)) continue;
        var hash = /^[a-f0-9]{40}$|^[a-f0-9]{64}$/i.test(candidate);
        var uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(candidate);
        if ((hash && !ownSecret) || (uuid && !(ownSecret && provider && creation))) continue;
        if (!best || candidate.length > best.length) best = candidate;
      }
      if (best) {
        var name = suggestedName(context, provider);
        var score = 0.45 + (ownSecret ? 0.15 : 0) + (nearbySecret ? 0.05 : 0) + (provider ? 0.05 : 0) + (creation ? 0.1 : 0) + (context.field ? 0.05 : 0);
        result = { value: best, type: (provider ? provider[1] + " " : "") + roleName(label || nearby).toLowerCase().replace(/_/g, " ") + " (suggested)",
                   service: provider ? provider[1] : "", name: name, kind: "token", score: score, basis: "context",
                   environment: localEnvironment(label), evidence: [] };
        if (ownSecret) result.evidence.push("Credential label");
        if (nearbySecret) result.evidence.push("Nearby credential wording");
        if (provider) result.evidence.push("Provider page or variable name");
        if (creation) result.evidence.push("Creation or copy workflow");
      }
    }
    if (!result) return null;
    if (result.basis !== "context") {
      result.score += bonus;
      if (context.variable && (SECRET_WORDS.test(words(context.variable)) || /\b(?:database url|db url|redis url|mongodb uri|dsn|connection url)\b/i.test(words(context.variable)))) {
        result.name = /^[A-Z_][A-Z0-9_]{2,63}$/.test(context.variable) ? context.variable : snake(context.variable) || result.name;
      }
    }
    result.score = Math.min(docs ? 0.65 : 1, result.score);
    result.shownOnce = once;
    result.confidence = result.score >= 0.75 ? "high" : result.score >= 0.5 ? "medium" : "low";
    return result.confidence === "low" ? null : result;
  }

  /// Every distinct secret in a block of text (several keys can share one code block).
  function findAll(text, context) {
    context = context || {};
    var found = [], seen = {};
    var pieces = [text];
    // Split long text into lines so one value doesn't hide another; private keys stay whole.
    if (text.length > 120 && !PEM_ANY.test(text)) pieces = text.split(/\s*\n\s*|\s{2,}|[;,"'`]/);
    for (var i = 0; i < pieces.length; i++) {
      var piece = pieces[i];
      if (!piece || piece.length < 16) continue;
      // KEY=value and "key": "value" put the label right next to the value.
      var kv = piece.match(/^\s*([A-Za-z_][A-Za-z0-9_.-]{1,60})\s*[:=]\s*(.+)$/);
      var ctx = kv ? Object.assign({}, context, { variable: kv[1], label: kv[1] }) : context;
      var r = classify(kv ? kv[2] : piece, ctx);
      if (r && !seen[r.value]) { seen[r.value] = true; found.push(r); }
    }
    return found;
  }

  var FIELD_KINDS = [
    { re: /\b(private key|ssh key|signing key|pem|p8|key file)\b/, type: "Private key", kind: "key" },
    { re: /\b(certificate|cert|crt|ca bundle)\b/, type: "Certificate", kind: "value" },
    { re: /\b(connection string|connection url|database url|db url|dsn|mongodb uri|redis url)\b/, type: "Connection string", kind: "password" },
    { re: /\b(client secret|webhook secret|signing secret|secret key|api secret|shared secret|secret)\b/, type: "Secret", kind: "token" },
    { re: /\b(api key|apikey|access key|api token|access token|auth token|authentication token|bearer|personal access token|token)\b/, type: "API key or token", kind: "token" }
  ];
  var NOT_SECRET_FIELD = /\b(user ?name|e ?mail|search|captcha|verification|one ?time|otp|2fa|mfa|code|csrf|authenticity|coupon|promo|card|cvc|cvv|confirm|recovery)\b/;

  /// What kind of secret a form field expects, from its label, placeholder, name, id and autocomplete hint, or null.
  /// Never looks at the value. `field`: { label, placeholder, name, id, autocomplete }.
  function fieldKind(field) {
    field = field || {};
    if (/^(current-password|new-password|one-time-code|username|email|cc-)/.test(field.autocomplete || "")) return null;
    var text = [field.label, field.placeholder, field.name, field.id].filter(Boolean).join(" ")
      .replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_\-.]+/g, " ").toLowerCase();
    if (!text || NOT_SECRET_FIELD.test(text)) return null;
    for (var i = 0; i < FIELD_KINDS.length; i++) if (FIELD_KINDS[i].re.test(text)) return { type: FIELD_KINDS[i].type, kind: FIELD_KINDS[i].kind };
    return null;   // a password field that names no key is a sign-in password
  }

  function preview(v) {
    if (/^-----BEGIN/.test(v)) return v.split("\n")[0];
    var cut = v.search(/[_-][A-Za-z0-9]/);
    var head = cut > 0 && cut < 12 ? v.slice(0, cut + 1) : v.slice(0, 6);
    return head + "…" + v.slice(-4);
  }

  var api = { classify: classify, findAll: findAll, fieldKind: fieldKind, preview: preview, entropy: entropy, rules: RULES };
  root.LatchkeyDetector = api;
  if (typeof module !== "undefined") module.exports = api;
})(typeof window !== "undefined" ? window : globalThis);
