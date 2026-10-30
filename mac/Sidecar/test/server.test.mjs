import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../src/server.mjs';

function setup(over = {}) {
  const out = [];
  const state = { connected: true, planEnabled: true, account: { id: 'a1', label: 'me@example.com', connected: true } };
  const client = {
    status: async () => state,
    listModels: async () => [{ id: 'm1', name: 'Model 1' }, { id: 'm2', name: 'Model 2' }],
    generate: async ({ model, input, instructions, onProgress }) => { onProgress({ phase: 'receiving', outputChars: 5 }); return { text: `${model}|${instructions}|${input}`.padEnd(100, '.') }; },
    signIn: async () => {},
    disconnect: async () => ({ revoked: true }),
    ...over,
  };
  const urlSink = { fn: null };
  return { out, client, urlSink, handle: createHandler({ client, write: o => out.push(o), urlSink, probeStore: () => ({}) }) };
}

test('status reports account and models', async () => {
  const { out, handle } = setup();
  await handle({ id: 1, type: 'status' });
  assert.deepEqual(out[0], { id: 1, done: true, signedIn: true, connected: true, planEnabled: true, account: 'me@example.com', models: [{ id: 'm1', name: 'Model 1' }, { id: 'm2', name: 'Model 2' }] });
});

test('status when signed out has no models', async () => {
  const { out, handle } = setup({ status: async () => ({ connected: false, planEnabled: false }) });
  await handle({ id: 'x', type: 'status' });
  assert.equal(out[0].signedIn, false);
  assert.equal(out[0].account, null);
  assert.deepEqual(out[0].models, []);
});

test('complete streams deltas then done, defaults to the first model', async () => {
  const { out, handle } = setup();
  await handle({ id: 2, type: 'complete', system: 'sys', prompt: 'hello', maxTokens: 50 });
  const deltas = out.filter(o => 'delta' in o);
  const done = out.at(-1);
  assert.ok(out.some(o => o.progress));
  assert.equal(done.done, true);
  assert.equal(deltas.map(d => d.delta).join(''), done.text);
  assert.ok(done.text.startsWith('m1|sys\n\nKeep the answer under about 50 tokens.|hello'));
});

test('signIn reports the URL, then status', async () => {
  const { out, handle, urlSink } = setup({ signIn: async () => { urlSink.fn('http://127.0.0.1:1/auth'); } });
  await handle({ id: 3, type: 'signIn' });
  assert.deepEqual(out[0], { id: 3, url: 'http://127.0.0.1:1/auth' });
  assert.equal(out[1].done, true);
});

test('cancel aborts an in-flight complete', async () => {
  let started;
  const ready = new Promise(r => { started = r; });
  const { out, handle } = setup({ generate: ({ signal }) => new Promise((_, no) => { started(); signal.addEventListener('abort', () => no(Object.assign(new Error('x'), { code: 'canceled', name: 'ChatGptError' }))); }) });
  const p = handle({ id: 4, type: 'complete', system: '', prompt: 'p', model: 'm' });
  await ready;
  await handle({ id: 5, type: 'cancel', target: 4 });
  await p;
  assert.deepEqual(out.find(o => o.id === 4), { id: 4, error: { code: 'canceled', message: 'Canceled.' } });
});

test('errors never leak raw exception text', async () => {
  const { out, handle } = setup({ generate: async () => { throw new Error('secret-token-123'); } });
  await handle({ id: 6, type: 'complete', system: '', prompt: 'p', model: 'm' });
  assert.equal(out[0].error.code, 'unavailable');
  assert.ok(!JSON.stringify(out).includes('secret-token'));
});

test('bad requests are rejected', async () => {
  const { out, handle } = setup();
  await handle({ id: 7, type: 'complete', system: '', prompt: 5 });
  await handle({ id: 8, type: 'nope' });
  assert.equal(out[0].error.code, 'bad-request');
  assert.equal(out[1].error.code, 'bad-request');
});
