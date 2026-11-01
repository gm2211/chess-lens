import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createProviders, publicError } from '../src/providers.mjs';

// Stands in for byos classifyProviderError (the real one is bundled in by esbuild).
const classifyProviderError = e => ({ kind: e?.name === 'AbortError' ? 'aborted' : [401, 403].includes(e?.status) ? 'auth' : [402, 429].includes(e?.status) ? 'quota' : 'unavailable' });
import { createHandler } from '../src/server.mjs';
import { deviceSignIn, TOKEN_URL, DEVICE_CODE_URL } from '../src/grok-oauth.mjs';

const KEY = 'sk-test-SECRET-KEY-123';

// Fake @byos/providers adapter: records the token and requests it receives.
function fakeByos(name, { models = [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }], acceptedKey = KEY } = {}) {
  const calls = { list: [], stream: [] };
  const p = {
    id: name,
    listModels: async (token) => { calls.list.push(token); if (![acceptedKey, 'oauth-access', 'first-access'].includes(token)) throw Object.assign(new Error(`Incorrect API key ${token}`), { name: 'ProviderRequestError', status: 401 }); return models; },
    stream: async function* (token, req) { calls.stream.push({ token, req }); yield { type: 'reasoning', text: 'hmm' }; yield { type: 'text', text: 'He' }; yield { type: 'text', text: 'llo' }; yield { type: 'done' }; },
  };
  return { p, calls };
}

function memVault() {
  const m = new Map();
  const fn = (n) => ({ get: async () => m.get(n) ?? null, set: async v => { m.set(n, v); }, delete: async () => { m.delete(n); } });
  fn.m = m; return fn;
}

function setup(over = {}, claudeKey = KEY) {
  const fakes = { claude: fakeByos('claude', { acceptedKey: claudeKey }), openrouter: fakeByos('openrouter'), grok: fakeByos('grok'), groq: fakeByos('groq'), huggingface: fakeByos('huggingface') };
  const vault = memVault();
  const claudeState = { connected: false, calls: [], portBusy: false };
  const claude = {
    status: async () => ({ connected: claudeState.connected, account: claudeState.connected ? { label: 'me@example.com' } : undefined }),
    signIn: async () => { if (claudeState.portBusy) throw Object.assign(new Error('busy'), { name: 'ClaudeError', code: 'port-in-use' }); claudeState.connected = true; },
    beginPasteSignIn: () => ({ url: 'https://claude.ai/oauth/authorize?paste=1' }),
    completePasteSignIn: async code => { claudeState.calls.push(code); claudeState.connected = true; },
    disconnect: async () => { claudeState.connected = false; },
    listModels: async () => [{ id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5' }],
    generate: async r => { claudeState.calls.push(r); r.onText('Hi'); r.onText(' there'); return { text: 'Hi there' }; },
  };
  const chatgpt = {
    status: async () => ({ connected: true, planEnabled: true, account: { id: 'a1', label: 'gpt@example.com' } }),
    listModels: async () => [{ id: 'g1', name: 'GPT 1' }],
    signIn: async () => {}, disconnect: async () => ({ revoked: true }),
    generate: async ({ model, instructions, input, onProgress }) => { onProgress({ phase: 'receiving', outputChars: 3 }); return { text: `${model}|${instructions}|${input}` }; },
  };
  const byos = {
    claude: () => fakes.claude.p, openrouter: () => fakes.openrouter.p, grok: () => fakes.grok.p, groq: () => fakes.groq.p, huggingface: () => fakes.huggingface.p,
    classifyProviderError,
  };
  const providers = createProviders({ chatgpt, claude, byos, vault, ...over });
  const out = [];
  const urlSink = { fn: null };
  const handle = createHandler({ providers, write: o => out.push(o), urlSink, probeStore: () => ({}) });
  return { providers, handle, out, vault, fakes, claudeState };
}

test('providers: all seven sidecar providers with auth kinds and setup links', async () => {
  const { handle, out } = setup();
  await handle({ id: 1, type: 'providers' });
  const byId = Object.fromEntries(out[0].providers.map(p => [p.id, p]));
  assert.deepEqual(Object.keys(byId), ['chatgpt', 'claude', 'claudeAPI', 'openrouter', 'grok', 'groq', 'huggingface']);
  assert.equal(byId.chatgpt.authKind, 'oauth'); assert.equal(byId.claude.authKind, 'oauth'); assert.equal(byId.claude.flow, 'loopback+paste');
  assert.equal(byId.grok.authKind, 'both'); assert.equal(byId.grok.flow, 'device');
  for (const k of ['claudeAPI', 'openrouter', 'groq', 'huggingface']) { assert.equal(byId[k].authKind, 'apiKey'); assert.match(byId[k].setupURL, /^https:\/\//); }
  for (const p of out[0].providers) assert.ok(p.name && typeof p.setupText === 'string');
});

test('chatgpt: status, models, complete with a length hint', async () => {
  const { handle, out } = setup();
  await handle({ id: 1, type: 'status', provider: 'chatgpt' });
  assert.deepEqual(out[0], { id: 1, done: true, ready: true, account: 'gpt@example.com', models: [{ id: 'g1', name: 'GPT 1' }] });
  await handle({ id: 2, type: 'complete', provider: 'chatgpt', system: 'sys', prompt: 'p', maxTokens: 50 });
  assert.ok(out.at(-1).text.startsWith('g1|sys\n\nKeep the answer under about 50 tokens.|p'));
});

test('claude (subscription): loopback sign-in, live models, streaming complete with a real token cap', async () => {
  const { handle, out, claudeState } = setup();
  await handle({ id: 1, type: 'status', provider: 'claude' });
  assert.equal(out[0].ready, false);
  await handle({ id: 2, type: 'signIn', provider: 'claude' });
  assert.deepEqual(out.at(-1), { id: 2, done: true, ready: true, account: 'me@example.com', models: [{ id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5' }] });
  await handle({ id: 3, type: 'complete', provider: 'claude', system: 'sys', prompt: 'p', maxTokens: 200 });
  assert.deepEqual(out.filter(o => o.id === 3 && o.delta).map(o => o.delta), ['Hi', ' there']);
  const req = claudeState.calls.at(-1);
  assert.equal(req.model, 'claude-sonnet-5-5'); assert.equal(req.instructions, 'sys'); assert.equal(req.maxTokens, 200);
});

test('claude (subscription): a busy loopback port falls back to the paste flow, then submitCode finishes', async () => {
  const { handle, out, claudeState } = setup();
  claudeState.portBusy = true;
  await handle({ id: 1, type: 'signIn', provider: 'claude' });
  assert.deepEqual(out[0], { id: 1, url: 'https://claude.ai/oauth/authorize?paste=1' });
  assert.equal(out[1].ready, false); assert.equal(out[1].awaitingCode, true);
  await handle({ id: 2, type: 'submitCode', provider: 'claude', code: 'CODE#STATE' });
  assert.equal(out.at(-1).ready, true);
  assert.equal(claudeState.calls[0], 'CODE#STATE');
  await handle({ id: 3, type: 'signOut', provider: 'claude' });
  await handle({ id: 4, type: 'status', provider: 'claude' });
  assert.equal(out.at(-1).ready, false);
});

test('claude (subscription): explicit paste mode skips the loopback', async () => {
  const { handle, out } = setup();
  await handle({ id: 1, type: 'signIn', provider: 'claude', mode: 'paste' });
  assert.equal(out[0].url.includes('paste=1'), true); assert.equal(out[1].awaitingCode, true);
});

for (const id of ['claudeAPI', 'openrouter', 'groq', 'huggingface', 'grok']) {
  const fake = id === 'claudeAPI' ? 'claude' : id;
  test(`${id}: key validated against the provider, stored in the vault only, never echoed; models live; streams`, async () => {
    const { handle, out, vault, fakes } = setup();
    await handle({ id: 1, type: 'status', provider: id });
    assert.equal(out[0].ready, false);
    await handle({ id: 2, type: 'signIn', provider: id, apiKey: `  ${KEY} ` });
    assert.deepEqual(out.at(-1), { id: 2, done: true, ready: true, account: 'API key', models: [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }] });
    assert.deepEqual(JSON.parse(vault.m.get(id)), { kind: 'key', key: KEY });
    assert.ok(!JSON.stringify(out).includes('SECRET'));
    await handle({ id: 3, type: 'complete', provider: id, model: 'b', system: 'sys', prompt: 'p', maxTokens: 30 });
    assert.deepEqual(out.filter(o => o.id === 3 && o.delta).map(o => o.delta), ['He', 'llo']);
    assert.equal(out.at(-1).text, 'Hello');
    const sent = fakes[fake].calls.stream[0];
    assert.equal(sent.token, KEY); assert.equal(sent.req.model, 'b');
    assert.deepEqual(sent.req.messages.map(m => m.role), ['system', 'user']);
    assert.ok(!JSON.stringify(out).includes('SECRET'));
    await handle({ id: 4, type: 'signOut', provider: id });
    assert.equal(vault.m.has(id), false);
    await handle({ id: 5, type: 'complete', provider: id, system: '', prompt: 'p' });
    assert.equal(out.at(-1).error.code, 'reconnect-required');
  });

  test(`${id}: a rejected key is not stored and its text is redacted`, async () => {
    const { handle, out, vault } = setup();
    await handle({ id: 1, type: 'signIn', provider: id, apiKey: 'sk-test-WRONG-9' });
    assert.equal(out[0].error.code, 'auth-failed');
    assert.match(out[0].error.message, /did not accept that key/);
    assert.ok(!out[0].error.message.includes('WRONG-9'));
    assert.equal(vault.m.has(id), false);
    await handle({ id: 3, type: 'signIn', provider: id, apiKey: 'has space' });
    assert.equal(out[1].error.code, 'bad-request');
    if (id !== 'grok') { await handle({ id: 2, type: 'signIn', provider: id, apiKey: '' }); assert.equal(out[2].error.code, 'bad-request'); } // grok: empty means OAuth
  });
}

test('claudeAPI no longer pre-refuses a pasted subscription token (byos claude() spends it)', async () => {
  const { handle, out } = setup({}, 'sk-ant-oat01-abc');
  await handle({ id: 1, type: 'signIn', provider: 'claudeAPI', apiKey: 'sk-ant-oat01-abc' });
  assert.equal(out[0].error, undefined);
});

test('a stored key the provider later rejects shows as not ready', async () => {
  const { handle, out, vault } = setup();
  await vault('groq').set(JSON.stringify({ kind: 'key', key: 'revoked' }));
  await handle({ id: 1, type: 'status', provider: 'groq' });
  assert.equal(out[0].ready, false); assert.equal(out[0].error, 'reconnect-required');
});

test('publicError redacts secrets and maps statuses', () => {
  const e = publicError(Object.assign(new Error('bad key sk-123 here'), { name: 'ProviderRequestError', status: 429 }), { secrets: ['sk-123'], classify: classifyProviderError });
  assert.equal(e.code, 'quota'); assert.ok(!e.message.includes('sk-123'));
  assert.equal(publicError(new TypeError('fetch failed'), { classify: classifyProviderError }).message, 'The provider is unavailable. Try again later.');
});

// --- Grok device-code sign-in ------------------------------------------------------------------------
function grokFetch(script) {
  const calls = [];
  const fetch = async (url, init) => {
    const form = Object.fromEntries(new URLSearchParams(String(init.body)));
    calls.push({ url, form });
    return script(url, form, calls.length);
  };
  return { fetch, calls };
}

test('grok: device flow emits URL + user code, polls through pending/slow_down, stores tokens, refreshes later', async () => {
  let clock = 1_000_000;
  const { fetch, calls } = grokFetch((url, form, n) => {
    if (url === DEVICE_CODE_URL) return Response.json({ device_code: 'dev', user_code: 'ABCD-1234', verification_uri: 'https://x.ai/device', verification_uri_complete: 'https://x.ai/device?c=ABCD-1234', interval: 1, expires_in: 300 });
    if (form.grant_type === 'refresh_token') return Response.json({ access_token: 'oauth-access', expires_in: 3600 });
    if (n === 2) return Response.json({ error: 'authorization_pending' }, { status: 400 });
    if (n === 3) return Response.json({ error: 'slow_down' }, { status: 400 });
    return Response.json({ access_token: 'first-access', refresh_token: 'r1', expires_in: 3600 });
  });
  const { handle, out, vault, fakes } = setup({ fetch, now: () => clock, sleep: async () => { clock += 1000; } });
  await handle({ id: 1, type: 'signIn', provider: 'grok' });
  assert.deepEqual(out[0], { id: 1, url: 'https://x.ai/device?c=ABCD-1234', userCode: 'ABCD-1234' });
  assert.equal(out[1].ready, true);
  assert.equal(calls.filter(c => c.form.grant_type?.includes('device_code')).length, 3);
  const rec = JSON.parse(vault.m.get('grok'));
  assert.equal(rec.kind, 'oauth'); assert.equal(rec.access, 'first-access'); assert.equal(rec.refresh, 'r1');
  assert.ok(!JSON.stringify(out).includes('first-access'));
  // Expired access token: refreshed with the stored refresh token before the provider call.
  clock += 3_600_000;
  await handle({ id: 2, type: 'complete', provider: 'grok', model: 'a', system: '', prompt: 'p' });
  assert.equal(calls.at(-1).form.refresh_token, 'r1');
  assert.equal(fakes.grok.calls.stream.at(-1).token, 'oauth-access');
  assert.equal(JSON.parse(vault.m.get('grok')).refresh, 'r1');
});

test('grok: declined, expired and unreachable sign-ins fail with clear codes', async () => {
  const run = (script) => deviceSignIn({ fetch: grokFetch(script).fetch, emit() {}, sleep: async () => {} });
  const start = Response.json({ device_code: 'd', user_code: 'U', verification_uri: 'https://x.ai/d', interval: 1, expires_in: 300 });
  await assert.rejects(run(url => url === DEVICE_CODE_URL ? start.clone() : Response.json({ error: 'access_denied' }, { status: 400 })), /declined/);
  await assert.rejects(run(url => url === DEVICE_CODE_URL ? start.clone() : Response.json({ error: 'expired_token' }, { status: 400 })), /expired/);
  await assert.rejects(run(() => { throw new Error('offline'); }), e => e.code === 'unavailable');
});

test('grok: a rejected refresh clears the credential and asks for sign-in', async () => {
  const { fetch } = grokFetch(() => Response.json({ error: 'invalid_grant' }, { status: 400 }));
  const { handle, out, vault } = setup({ fetch, now: () => 5_000_000 });
  await vault('grok').set(JSON.stringify({ kind: 'oauth', access: 'old', refresh: 'r', expiresAt: 1 }));
  await handle({ id: 1, type: 'complete', provider: 'grok', system: '', prompt: 'p', model: 'a' });
  assert.equal(out[0].error.code, 'reconnect-required');
  assert.equal(vault.m.has('grok'), false);
});

test('grok: an API key works beside OAuth', async () => {
  const { handle, out, vault } = setup();
  await handle({ id: 1, type: 'signIn', provider: 'grok', apiKey: KEY });
  assert.equal(out.at(-1).ready, true);
  assert.equal(JSON.parse(vault.m.get('grok')).kind, 'key');
});
