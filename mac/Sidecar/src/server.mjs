// Request handler for the Chess Lens sidecar. Pure of stdio so tests can inject fake providers.
//
// Wire protocol (one JSON object per line, both directions). Every command except ping/probe/cancel/providers
// takes `provider` (chatgpt | claude | claudeAPI | openrouter | grok | groq | huggingface):
//   in : {id, type: "providers"}                                   -> {providers: [{id,name,authKind,setupText,setupURL,flow}]}
//        {id, type: "status", provider}                            -> {ready, account, models: [{id,name}], error?}
//        {id, type: "signIn", provider, apiKey?, mode?}            OAuth: {id, url, userCode?} then the status reply
//                                                                  (+ awaitingCode: true when a pasted code is needed);
//                                                                  key: validates against the provider, stores in the Keychain.
//        {id, type: "submitCode", provider, code}                  paste-code fallback -> status
//        {id, type: "signOut", provider}
//        {id, type: "complete", provider, model?, system, prompt, maxTokens?}
//        {id, type: "cancel", target} | "probe" | "ping"
//   out: {id, url} {id, progress} {id, delta} {id, done: true, ...} {id, error: {code, message}}
// Keys and tokens never leave this process; replies carry account labels, model ids and generated text only.

import { SAFE_NAMES } from './errors.mjs';

const MODEL_TTL_MS = 60_000;
const CHUNK = 48;

export function createHandler({ providers, write, urlSink = { fn: null }, probeStore }) {
  const inflight = new Map(); // id -> AbortController
  const models = new Map();   // provider -> {at, list}
  let active = null;          // the sign-in in progress: {ctl, done}

  const fail = (id, error) => {
    const code = typeof error?.code === 'string' ? error.code : 'unavailable';
    const shown = code === 'bad-request' || SAFE_NAMES.has(error?.name);
    write({ id, error: { code, message: shown ? String(error.message) : 'The operation could not be completed.' } });
  };
  const bad = message => Object.assign(new Error(message), { code: 'bad-request' });
  const str = (v, max, name) => { if (typeof v !== 'string' || v.length > max) throw bad(`${name} must be a string up to ${max} characters`); return v; };
  const adapter = req => {
    const a = providers.get(str(req.provider, 40, 'provider'));
    if (!a) throw bad(`unknown provider: ${String(req.provider).slice(0, 40)}`);
    return a;
  };

  async function listModels(name, a, signal) {
    const hit = models.get(name);
    if (hit && Date.now() - hit.at < MODEL_TTL_MS && hit.list.length) return hit.list;
    const list = await a.listModels(signal);
    models.set(name, { at: Date.now(), list });
    return list;
  }

  async function status(id, a, extra = {}) {
    const s = await a.status();
    let list = [], error, ready = s.ready;
    if (s.ready) {
      try { list = await listModels(a.meta.id, a); } catch (e) {
        error = typeof e?.code === 'string' ? e.code : 'unavailable';
        // A key the provider rejects is not usable; other failures leave the account ready.
        if (error === 'reconnect-required') ready = false;
      }
    }
    write({ id, done: true, ready, account: s.account ?? null, models: list.map(m => ({ id: m.id, name: m.name })), ...(error ? { error } : {}), ...extra });
  }

  async function signIn(id, req, ctl) {
    const a = adapter(req);
    // A new sign-in supersedes one still waiting (e.g. switching from the browser flow to the paste-code flow).
    if (active) { active.ctl.abort(); await active.done; }
    let release;
    active = { ctl, done: new Promise(r => { release = r; }) };
    urlSink.fn = (url, extra = {}) => write({ id, url, ...extra });
    let result;
    try {
      const apiKey = req.apiKey === undefined ? undefined : str(req.apiKey, 1024, 'apiKey');
      result = await a.signIn({ apiKey, mode: req.mode === 'paste' ? 'paste' : undefined, emit: urlSink.fn, signal: ctl.signal });
      models.delete(a.meta.id);
    } finally { active = null; urlSink.fn = null; release(); }
    await status(id, a, result?.awaitingCode ? { awaitingCode: true } : {});
  }

  async function complete(id, req, ctl) {
    const a = adapter(req);
    const system = str(req.system ?? '', 100_000, 'system');
    const prompt = str(req.prompt, 200_000, 'prompt');
    if (!prompt.trim()) throw bad('prompt is empty');
    let model = req.model;
    if (model !== undefined) str(model, 200, 'model');
    else {
      const list = await listModels(a.meta.id, a, ctl.signal);
      if (!list.length) throw Object.assign(new Error('No models are available.'), { code: 'unavailable', name: 'PublicError' });
      model = list[0].id;
    }
    const max = Number.isInteger(req.maxTokens) && req.maxTokens > 0 ? req.maxTokens : undefined;
    const { text, streamed } = await a.complete({
      model, system, prompt, maxTokens: max, signal: ctl.signal,
      onDelta: d => write({ id, delta: d }),
      onProgress: p => write({ id, progress: { phase: p.phase, outputChars: p.outputChars } }),
    });
    // Providers that only return a finished answer are replayed in chunks.
    if (!streamed) for (let i = 0; i < text.length; i += CHUNK) {
      if (ctl.signal.aborted) return;
      write({ id, delta: text.slice(i, i + CHUNK) });
    }
    write({ id, done: true, text });
  }

  async function probe(id) {
    // Round-trips a throwaway Keychain item to prove the Keychain works from this process (sandbox check).
    const entry = probeStore();
    const secret = `probe-${Date.now()}`;
    await entry.setPassword(secret);
    const back = await entry.getPassword();
    await entry.deletePassword();
    write({ id, done: true, keychain: back === secret });
  }

  return async function handle(req) {
    const id = req?.id;
    try {
      if (typeof id !== 'string' && typeof id !== 'number') return;
      const ctl = new AbortController();
      switch (req.type) {
        case 'ping': write({ id, done: true }); return;
        case 'probe': await probe(id); return;
        case 'providers': write({ id, done: true, providers: [...providers.values()].map(a => ({ ...a.meta })) }); return;
        case 'status': await status(id, adapter(req)); return;
        case 'signOut': {
          const a = adapter(req);
          await a.signOut();
          models.delete(a.meta.id);
          write({ id, done: true });
          return;
        }
        case 'submitCode': {
          const a = adapter(req);
          if (!a.submitCode) throw bad('this provider has no paste-code sign-in');
          await a.submitCode(str(req.code, 4096, 'code'));
          models.delete(a.meta.id);
          await status(id, a);
          return;
        }
        case 'cancel': inflight.get(req.target)?.abort(); write({ id, done: true }); return;
        case 'signIn':
        case 'complete':
          inflight.set(id, ctl);
          try { await (req.type === 'signIn' ? signIn(id, req, ctl) : complete(id, req, ctl)); }
          finally { inflight.delete(id); }
          return;
        default: throw bad(`unknown request type: ${String(req.type).slice(0, 40)}`);
      }
    } catch (e) {
      if (e?.code === 'canceled') write({ id, error: { code: 'canceled', message: 'Canceled.' } });
      else fail(id, e);
    }
  };
}
