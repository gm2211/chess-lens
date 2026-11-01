import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../src/server.mjs';

// A minimal fake adapter; per-provider behavior is covered in providers.test.mjs.
function fake(over = {}) {
  const a = {
    meta: { id: 'fake', name: 'Fake', authKind: 'oauth', flow: 'loopback', setupText: '', setupURL: '' },
    status: async () => ({ ready: true, account: 'me@example.com' }),
    listModels: async () => [{ id: 'm1', name: 'Model 1' }, { id: 'm2', name: 'Model 2' }],
    signIn: async () => ({}),
    signOut: async () => {},
    complete: async ({ model, system, prompt, onProgress }) => { onProgress({ phase: 'receiving', outputChars: 5 }); return { text: `${model}|${system}|${prompt}`.padEnd(100, '.'), streamed: false }; },
    ...over,
  };
  return a;
}
function setup(over = {}) {
  const out = [];
  const adapter = fake(over);
  const urlSink = { fn: null };
  return { out, adapter, urlSink, handle: createHandler({ providers: new Map([['fake', adapter]]), write: o => out.push(o), urlSink, probeStore: () => ({}) }) };
}

test('providers lists metadata', async () => {
  const { out, handle } = setup();
  await handle({ id: 1, type: 'providers' });
  assert.deepEqual(out[0], { id: 1, done: true, providers: [{ id: 'fake', name: 'Fake', authKind: 'oauth', flow: 'loopback', setupText: '', setupURL: '' }] });
});

test('status reports ready, account and models', async () => {
  const { out, handle } = setup();
  await handle({ id: 1, type: 'status', provider: 'fake' });
  assert.deepEqual(out[0], { id: 1, done: true, ready: true, account: 'me@example.com', models: [{ id: 'm1', name: 'Model 1' }, { id: 'm2', name: 'Model 2' }] });
});

test('status when signed out has no models and makes no model call', async () => {
  let listed = false;
  const { out, handle } = setup({ status: async () => ({ ready: false, account: null }), listModels: async () => { listed = true; return []; } });
  await handle({ id: 'x', type: 'status', provider: 'fake' });
  assert.deepEqual(out[0], { id: 'x', done: true, ready: false, account: null, models: [] });
  assert.equal(listed, false);
});

test('a model list failure is reported without breaking status; a rejected credential is not ready', async () => {
  const a = setup({ listModels: async () => { throw Object.assign(new Error('x'), { code: 'unavailable', name: 'PublicError' }); } });
  await a.handle({ id: 1, type: 'status', provider: 'fake' });
  assert.equal(a.out[0].ready, true); assert.equal(a.out[0].error, 'unavailable');
  const b = setup({ listModels: async () => { throw Object.assign(new Error('x'), { code: 'reconnect-required', name: 'PublicError' }); } });
  await b.handle({ id: 1, type: 'status', provider: 'fake' });
  assert.equal(b.out[0].ready, false); assert.equal(b.out[0].error, 'reconnect-required');
});

test('complete replays non-streaming answers as deltas, defaults to the first model, and passes maxTokens', async () => {
  let seen;
  const { out, handle } = setup({ complete: async r => { seen = r; return { text: 'x'.repeat(100), streamed: false }; } });
  await handle({ id: 2, type: 'complete', provider: 'fake', system: 'sys', prompt: 'hello', maxTokens: 50 });
  const done = out.at(-1);
  assert.equal(done.done, true);
  assert.equal(out.filter(o => 'delta' in o).map(d => d.delta).join(''), done.text);
  assert.equal(seen.model, 'm1'); assert.equal(seen.maxTokens, 50);
});

test('streaming adapters forward their own deltas without replay', async () => {
  const { out, handle } = setup({ complete: async ({ onDelta }) => { onDelta('a'); onDelta('b'); return { text: 'ab', streamed: true }; } });
  await handle({ id: 2, type: 'complete', provider: 'fake', system: '', prompt: 'p', model: 'm' });
  assert.deepEqual(out, [{ id: 2, delta: 'a' }, { id: 2, delta: 'b' }, { id: 2, done: true, text: 'ab' }]);
});

test('thinking heartbeats are throttled to one a second', async () => {
  const { out, handle } = setup({ complete: async ({ onThinking }) => { for (let i = 0; i < 50; i++) onThinking(); return { text: 'x', streamed: true }; } });
  await handle({ id: 7, type: 'complete', provider: 'fake', system: '', prompt: 'p', model: 'm' });
  assert.equal(out.filter(o => o.thinking).length, 1);
});

test('signIn reports the URL (and user code), then status; awaitingCode is passed through', async () => {
  const { out, handle } = setup({ signIn: async ({ emit }) => { emit('http://127.0.0.1:1/auth', { userCode: 'AB-12' }); return { awaitingCode: true }; } });
  await handle({ id: 3, type: 'signIn', provider: 'fake' });
  assert.deepEqual(out[0], { id: 3, url: 'http://127.0.0.1:1/auth', userCode: 'AB-12' });
  assert.equal(out[1].done, true); assert.equal(out[1].awaitingCode, true);
});

test('signIn passes the api key and mode, submitCode and signOut dispatch', async () => {
  const calls = [];
  const { out, handle } = setup({ signIn: async r => { calls.push(['signIn', r.apiKey, r.mode]); return {}; }, submitCode: async c => { calls.push(['code', c]); }, signOut: async () => { calls.push(['out']); } });
  await handle({ id: 1, type: 'signIn', provider: 'fake', apiKey: 'k', mode: 'paste' });
  await handle({ id: 2, type: 'submitCode', provider: 'fake', code: 'abc#def' });
  await handle({ id: 3, type: 'signOut', provider: 'fake' });
  assert.deepEqual(calls, [['signIn', 'k', 'paste'], ['code', 'abc#def'], ['out']]);
  assert.equal(out.at(-1).done, true);
});

test('cancel aborts an in-flight complete', async () => {
  let started;
  const ready = new Promise(r => { started = r; });
  const { out, handle } = setup({ complete: ({ signal }) => new Promise((_, no) => { started(); signal.addEventListener('abort', () => no(Object.assign(new Error('x'), { code: 'canceled' }))); }) });
  const p = handle({ id: 4, type: 'complete', provider: 'fake', system: '', prompt: 'p', model: 'm' });
  await ready;
  await handle({ id: 5, type: 'cancel', target: 4 });
  await p;
  assert.deepEqual(out.find(o => o.id === 4), { id: 4, error: { code: 'canceled', message: 'Canceled.' } });
});

test('errors never leak raw exception text', async () => {
  const { out, handle } = setup({ complete: async () => { throw new Error('secret-token-123'); } });
  await handle({ id: 6, type: 'complete', provider: 'fake', system: '', prompt: 'p', model: 'm' });
  assert.equal(out[0].error.code, 'unavailable');
  assert.ok(!JSON.stringify(out).includes('secret-token'));
});

test('bad requests are rejected', async () => {
  const { out, handle } = setup();
  await handle({ id: 7, type: 'complete', provider: 'fake', system: '', prompt: 5 });
  await handle({ id: 8, type: 'nope' });
  await handle({ id: 9, type: 'status', provider: 'nonexistent' });
  await handle({ id: 10, type: 'status' });
  await handle({ id: 11, type: 'submitCode', provider: 'fake', code: 'x' });
  for (const o of out) assert.equal(o.error.code, 'bad-request');
  assert.equal(out.length, 5);
});

test('a new signIn supersedes one still waiting', async () => {
  let n = 0, started;
  const first = new Promise(r => { started = r; });
  const { out, handle } = setup({ signIn: ({ signal }) => (++n === 1 ? new Promise((_, no) => { started(); signal.addEventListener('abort', () => no(Object.assign(new Error('x'), { code: 'canceled' }))); }) : Promise.resolve({})) });
  const p1 = handle({ id: 1, type: 'signIn', provider: 'fake' });
  await first;
  await handle({ id: 2, type: 'signIn', provider: 'fake', mode: 'paste' });
  await p1;
  assert.deepEqual(out.find(o => o.id === 1), { id: 1, error: { code: 'canceled', message: 'Canceled.' } });
  assert.equal(out.find(o => o.id === 2 && o.done).ready, true);
});
