const { test } = require('node:test');
const assert = require('node:assert/strict');
const D = require('./Resources/detector.js');
// Fixed generated fixtures, never real credentials; failures assert properties without printing values.
function opaque(length = 48, alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_') {
  let state = 17392853, text = '';
  for (let i = 0; i < length; i++) { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; text += alphabet[(state >>> 16) % alphabet.length]; }
  return text;
}
const fixture = () => ['AQ', '.', opaque(64)].join('');

test('unfamiliar dotted key preserves its complete value and suggests Gemini from local context', () => {
  const value = fixture();
  const r = D.classify(value, { label: 'API Key', nearby: 'API key details. Copy your key now.', host: 'aistudio.google.com', title: 'API keys | Google AI Studio', field: true });
  assert.ok(r); assert.ok(r.value === value);
  assert.equal(r.name, 'GEMINI_API_KEY'); assert.equal(r.service, 'Google'); assert.equal(r.basis, 'context');
  assert.equal(r.confidence, 'high'); assert.ok(r.evidence.includes('Credential label'));
  assert.ok(r.evidence.every(item => !item.includes(value)));
});

test('a credential label works without a known provider, but a host/title alone does not', () => {
  const r = D.classify(opaque(), { label: 'Client secret', host: 'unknown.invalid', field: true });
  assert.ok(r); assert.equal(r.name, 'CLIENT_SECRET'); assert.equal(r.service, ''); assert.equal(r.confidence, 'medium');
  for (const context of [{}, { host: 'aistudio.google.com', title: 'API keys', path: '/apikeys', field: true },
    { nearby: 'API keys', host: 'aistudio.google.com', field: true }, { nearby: 'Copy now' }]) {
    assert.ok(D.classify(opaque(), context) === null);
  }
});

test('exact dashboard matching does not recognize lookalike or customer-hosted domains', () => {
  for (const host of ['aistudio.google.com.attacker.invalid', 'evil-aistudio.google.com', 'customer.vercel.app', 'clerk.attacker.invalid']) {
    const r = D.classify(fixture(), { label: 'API key', host });
    assert.ok(r); assert.equal(r.service, ''); assert.equal(r.name, 'API_KEY');
  }
  const r = D.classify(['sk', '_live_', opaque(40, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')].join(''), { host: 'clerk.attacker.invalid' });
  assert.equal(r.service, 'Stripe');
});

test('explicit variable names override generic naming and deployment-host hints', () => {
  const r = D.findAll('PAYMENTS_API_KEY=' + opaque(), { host: 'aistudio.google.com' })[0];
  assert.ok(r); assert.equal(r.name, 'PAYMENTS_API_KEY');
  const token = D.findAll('OPENAI_API_KEY=' + fixture(), { host: 'vercel.com' })[0];
  assert.equal(token.name, 'OPENAI_API_KEY'); assert.equal(token.service, 'OpenAI');
  const known = D.findAll('BILLING_SECRET_KEY=' + ['sk', '_live_', opaque(40, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')].join(''))[0];
  assert.equal(known.name, 'BILLING_SECRET_KEY');
  assert.equal(D.classify(opaque(), { label: 'clientSecret' }).name, 'CLIENT_SECRET');
  const named = D.classify(opaque(), { label: 'OpenAI API key', host: 'vercel.com' });
  assert.equal(named.name, 'OPENAI_API_KEY'); assert.equal(named.service, 'OpenAI');
});

test('nearby creation/reveal cues help isolated fields, without inventing an environment', () => {
  const r = D.classify(opaque(), { nearby: 'Your new access token. It will not be shown again.', host: 'github.com', field: true });
  assert.ok(r); assert.equal(r.name, 'GITHUB_TOKEN'); assert.equal(r.shownOnce, true);
  assert.equal(r.environment, undefined);
  assert.equal(D.classify(opaque(), { label: 'Production API key' }).environment, 'production');
  assert.equal(D.classify(opaque(), { label: 'Test and live API key' }).environment, undefined);
});

test('local negative labels outweigh general credential wording and creation cues', () => {
  const labels = ['Request ID', 'traceId', 'Project ID', 'Client ID', 'SHA256 hash', 'Checksum', 'Public API key', 'Publishable key', 'Anon key', 'CSRF token', 'Verification token'];
  for (const label of labels) {
    assert.ok(D.classify(opaque(), { label, nearby: 'Your new API key. Copy your key now.', host: 'aistudio.google.com', field: true }) === null, 'negative label must win');
  }
});

test('hashes and UUIDs on a key page stay decoys; explicitly labeled hex secrets can qualify', () => {
  const hash = opaque(64, '0123456789abcdef');
  const uuid = ['d90c713a','5306','4a18','ad01','c92f506b382e'].join('-');
  for (const value of [hash, uuid]) {
    assert.ok(D.classify(value, { nearby: 'API keys', host: 'aistudio.google.com', field: true }) === null);
  }
  assert.ok(D.classify(hash, { label: 'Client secret' }));
  assert.ok(D.classify(uuid, { label: 'Request ID', nearby: 'New API key', field: true }) === null);
});

test('samples, masked values, public keys, URLs and ordinary prose are excluded', () => {
  const contexts = [{ label: 'Example API key' }, { label: 'API key', nearby: 'Sample token for illustration' }];
  for (const context of contexts) assert.ok(D.classify(fixture(), context) === null);
  for (const value of ['https://assets.invalid/' + opaque(), 'theseAreOrdinaryDocumentationWordsWithoutAnyDigits', '*'.repeat(40), '1234567890'.repeat(5)]) {
    assert.ok(D.classify(value, { label: 'API key' }) === null);
  }
  const publicKey = ['pk', '_live_', opaque(40, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789')].join('');
  assert.ok(D.classify(publicKey, { label: 'Secret key', host: 'dashboard.stripe.com' }) === null);
});

test('documentation caps confidence and does not claim a token is valid', () => {
  const r = D.classify(fixture(), { label: 'API key', host: 'aistudio.google.com', nearby: 'New API key. Copy your key now.', field: true, title: 'API key documentation' });
  assert.ok(r); assert.equal(r.confidence, 'medium'); assert.ok(r.score <= 0.65);
  assert.ok(!Object.hasOwn(r, 'valid'));
});


test('public certificates and public key envelopes never become high-confidence secrets', () => {
  const value = opaque(64, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/');
  for (const envelope of [
    ['-----BEGIN ', 'PUBLIC KEY-----\n', value, '\n-----END ', 'PUBLIC KEY-----'].join(''),
    ['ssh-', 'ed25519 ', value, ' user@fixture.invalid'].join(''),
    ['-----BEGIN ', 'CERTIFICATE-----\n', value, '\n-----END ', 'CERTIFICATE-----'].join('')
  ]) {
    const r = D.classify(envelope, { label: 'Private key', nearby: 'New API key shown only once', host: 'aistudio.google.com', field: true });
    assert.ok(r); assert.equal(r.isPublic, true); assert.equal(r.confidence, 'medium'); assert.equal(r.shownOnce, false);
  }
});


test('opaque token punctuation and explicit long variable names are preserved', () => {
  const value = '_' + opaque() + '.segment==';
  const name = 'MY_SERVICE_PRODUCTION_PERSONAL_ACCESS_API_TOKEN';
  const r = D.findAll(name + '=' + value, {})[0];
  assert.ok(r); assert.ok(r.value === value); assert.equal(r.name, name);
  assert.ok(D.classify('/Users/person/.config/credentials.json', { label: 'API key file path' }) === null);
  const url = ['postgres', '://user:', opaque(30), '@db.fixture.invalid/service'].join('');
  const connection = D.findAll('ANALYTICS_DATABASE_URL=' + url)[0];
  assert.ok(connection); assert.equal(connection.name, 'ANALYTICS_DATABASE_URL');
});
