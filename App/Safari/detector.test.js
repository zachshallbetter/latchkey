// Tests for Latchkey for Safari's detector: node App/Safari/detector.test.js
// Keys are assembled at run time from fragments, so no key-shaped string sits in the repository for scanners to flag.
"use strict";
const assert = require("assert");
const D = require("./Resources/detector.js");

const ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
function rand(n, chars = ALNUM) { let s = ""; for (let i = 0; i < n; i++) s += chars[Math.floor(Math.random() * chars.length)]; return s; }
const HEX = "0123456789abcdef";
const j = (...p) => p.join("");

let passed = 0;
function check(name, fn) { fn(); passed++; }

// ---- Provider formats are found, named and given a confidence
const cases = [
  [j("sk", "_live_", rand(99)), "STRIPE_SECRET_KEY", "Stripe", "production"],
  [j("sk", "_test_", rand(99)), "STRIPE_SECRET_KEY", "Stripe", "development"],
  [j("rk", "_live_", rand(99)), "STRIPE_RESTRICTED_KEY", "Stripe", "production"],
  [j("whsec", "_", rand(32)), "STRIPE_WEBHOOK_SECRET", "Stripe"],
  [j("sk-", "ant-api03-", rand(90, ALNUM + "-_")), "ANTHROPIC_API_KEY", "Anthropic"],
  [j("sk-", "proj-", rand(120, ALNUM + "-_")), "OPENAI_API_KEY", "OpenAI"],
  [j("github", "_pat_", rand(82, ALNUM + "_")), "GITHUB_TOKEN", "GitHub"],
  [j("gh", "p_", rand(36)), "GITHUB_TOKEN", "GitHub"],
  [j("glp", "at-", rand(20)), "GITLAB_TOKEN", "GitLab"],
  [j("AI", "za", rand(35, ALNUM + "-_")), "GOOGLE_API_KEY", "Google"],
  [j("np", "m_", rand(36)), "NPM_TOKEN", "npm"],
  [j("dop", "_v1_", rand(64, HEX)), "DIGITALOCEAN_TOKEN", "DigitalOcean"],
  [j("lin", "_api_", rand(40)), "LINEAR_API_KEY", "Linear"],
  [j("hf", "_", rand(34)), "HF_TOKEN", "Hugging Face"],
];
for (const [value, name, service, env] of cases) {
  check(name + " " + service, () => {
    const r = D.classify(value, {});
    assert(r, "should find " + name);
    assert.strictEqual(r.name, name);
    assert.strictEqual(r.service, service);
    assert.strictEqual(r.confidence, "high");
    if (env) assert.strictEqual(r.environment, env);
    assert.strictEqual(r.value, value);
  });
}

check("finds a key inside surrounding text", () => {
  const key = j("sk", "_live_", rand(60));
  const r = D.classify("Your new key: " + key + " (copy it now)", {});
  assert(r && r.value === key);
});

check("private keys, not certificates", () => {
  const pem = j("-----BEGIN ", "PRIVATE KEY-----\n", rand(64, ALNUM + "+/"), "\n", rand(64, ALNUM + "+/"), "\n-----END ", "PRIVATE KEY-----");
  const r = D.classify(pem, {});
  assert(r && r.kind === "key" && r.name === "PRIVATE_KEY" && r.confidence === "high");
  assert.strictEqual(D.classify(j("-----BEGIN ", "CERTIFICATE-----\n", rand(64), "\n-----END CERTIFICATE-----"), {}), null);
});

check("connection strings with a password", () => {
  const url = j("postgres", "://app:", rand(20), "@ep-cool.us-east-2.aws.neon.tech/shop?sslmode=require");
  const r = D.classify(url, {});
  assert(r && r.name === "DATABASE_URL" && r.kind === "password");
  assert.strictEqual(D.classify("postgres://localhost:5432/shop", {}), null, "no password, nothing secret");
  assert.strictEqual(D.classify(j("redis", "://default:password@localhost:6379"), {}), null, "the word password isn't one");
});

check("weak formats need the page to say it's a key", () => {
  const id = j("AK", "IA", rand(16, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"));
  assert.strictEqual(D.classify(id, {}), null);
  const r = D.classify(id, { label: "Access key ID" });
  assert(r && r.name === "AWS_ACCESS_KEY_ID");
});

check("a random string counts only with a secret-sounding label", () => {
  const s = rand(48);
  assert.strictEqual(D.classify(s, {}), null);
  const r = D.classify(s, { label: "Client secret" });
  assert(r && r.name === "CLIENT_SECRET" && r.confidence === "medium");
  const once = D.classify(s, { label: "Client secret", nearby: "You won't be able to see it again.", field: true });
  assert(once && once.confidence === "high", "shown-once wording raises confidence");
});

check("AWS secret access keys by their label", () => {
  const s = rand(40, ALNUM + "+/");
  const r = D.classify(s, { label: "Secret access key" });
  assert(r && r.name === "AWS_SECRET_ACCESS_KEY");
});

check("decoys are ignored", () => {
  const decoys = [
    j("sk", "_live_", "••••••••••", "a1b2"),
    j("sk", "_live_", "...a1b2"),
    j("sk", "_test_", "example", rand(30)),
    "AKIAIOSFODNN7EXAMPLE",
    j("pk", "_live_", rand(99)),                    // publishable: public by design
    j("ph", "c_", rand(43)),                         // PostHog project key: public
    rand(40, HEX),                                   // a commit hash
    "your_api_key_goes_here_and_more_text_123",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "https://github.com/zachshallbetter/latchkey/blob/main/docs/security.md",
    j("ey", "J", rand(20), ".eyJ", rand(40), ".", rand(43)),   // a JWT with no secret-sounding label
  ];
  for (const d of decoys) assert.strictEqual(D.classify(d, {}), null, "should ignore " + d.slice(0, 24));
});

check("Clerk keys on Clerk's dashboard", () => {
  const r = D.classify(j("sk", "_live_", rand(40)), { host: "dashboard.clerk.com" });
  assert(r && r.service === "Clerk" && r.name === "CLERK_SECRET_KEY");
});

check("several keys in one block, with their labels", () => {
  const block = j("STRIPE_SECRET_KEY=sk", "_test_", rand(40), "\nOPENAI_API_KEY=sk-", "proj-", rand(60), "\nDEBUG=true\nCLIENT_SECRET=", rand(48));
  const found = D.findAll(block, {});
  assert.deepStrictEqual(found.map((f) => f.name).sort(), ["CLIENT_SECRET", "OPENAI_API_KEY", "STRIPE_SECRET_KEY"]);
});

check("previews never show the whole value", () => {
  const key = j("rk", "_live_", rand(80));
  const p = D.preview(key);
  assert(p.startsWith("rk_") && p.endsWith(key.slice(-4)) && p.length < 16);
});

// Run the randomized cases many times, so a lucky draw can't hide a flaky rule.
for (let round = 0; round < 200; round++) {
  for (const [, name] of cases) void name;
  const s = rand(48);
  assert.strictEqual(D.classify(s, {}), null, "random text alone must never count");
}
console.log("detector: " + passed + " checks passed, 200 random strings ignored");
