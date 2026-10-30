// Request handler for the Chess Lens sidecar. Pure of stdio so tests can inject a fake client.
//
// Wire protocol (one JSON object per line, both directions):
//   in : {id, type: "status" | "signIn" | "signOut" | "complete" | "cancel" | "probe" | "ping", ...}
//   out: {id, url}            sign-in URL to open in the browser (before the signIn reply)
//        {id, progress}       generation activity {phase, outputChars}
//        {id, delta}          text chunk of a complete request
//        {id, done: true, ...} final reply (complete: {text})
//        {id, error: {code, message}}
// Tokens never leave this process; replies carry account labels, model ids and generated text only.

const MODEL_TTL_MS = 60_000;
const CHUNK = 48;

export function createHandler({ client, write, urlSink = { fn: null }, probeStore }) {
  const inflight = new Map(); // id -> AbortController
  let signingIn = false;
  let models = { at: 0, list: [] };

  const fail = (id, error) => {
    const code = typeof error?.code === 'string' ? error.code : 'unavailable';
    write({ id, error: { code, message: code === 'bad-request' ? String(error.message) : (error?.message && error.name === 'ChatGptError' ? error.message : 'The operation could not be completed.') } });
  };
  const bad = (message) => Object.assign(new Error(message), { code: 'bad-request' });
  const str = (v, max, name) => { if (typeof v !== 'string' || v.length > max) throw bad(`${name} must be a string up to ${max} characters`); return v; };

  async function listModels(signal) {
    if (Date.now() - models.at < MODEL_TTL_MS && models.list.length) return models.list;
    models = { at: Date.now(), list: await client.listModels(signal) };
    return models.list;
  }

  async function status(id) {
    const s = await client.status();
    const signedIn = s.connected && s.planEnabled;
    let list = [], modelsError;
    if (signedIn) {
      try { list = await listModels(); } catch (e) { modelsError = e?.code ?? 'unavailable'; }
    }
    write({ id, done: true, signedIn, connected: s.connected, planEnabled: s.planEnabled,
      account: s.account?.label ?? null, models: list.map(m => ({ id: m.id, name: m.name })), ...(modelsError ? { modelsError } : {}) });
  }

  async function signIn(id, ctl) {
    if (signingIn) throw Object.assign(new Error('A sign-in is already in progress.'), { code: 'busy', name: 'ChatGptError' });
    signingIn = true;
    urlSink.fn = url => write({ id, url });
    try {
      const s = await client.status();
      // Reconnect the saved registration instead of piling up new ones.
      await client.signIn({ accountId: s.account?.id, enablePlan: true, signal: ctl.signal });
      models = { at: 0, list: [] };
    } finally { signingIn = false; urlSink.fn = null; }
    await status(id);
  }

  async function complete(id, req, ctl) {
    const system = str(req.system ?? '', 100_000, 'system');
    const prompt = str(req.prompt, 200_000, 'prompt');
    if (!prompt.trim()) throw bad('prompt is empty');
    let model = req.model;
    if (model !== undefined) str(model, 200, 'model');
    else {
      const list = await listModels(ctl.signal);
      if (!list.length) throw Object.assign(new Error('No models are available.'), { code: 'unavailable', name: 'ChatGptError' });
      model = list[0].id;
    }
    // The kit exposes no token cap, so maxTokens is passed to the model as a length hint.
    const max = Number.isInteger(req.maxTokens) && req.maxTokens > 0 ? req.maxTokens : undefined;
    const instructions = max ? `${system}\n\nKeep the answer under about ${max} tokens.`.trim() : system;
    const { text } = await client.generate({
      model, input: prompt, ...(instructions ? { instructions } : {}), signal: ctl.signal,
      onProgress: p => write({ id, progress: { phase: p.phase, outputChars: p.outputChars } }),
    });
    // generate() resolves only with a completed response, so deltas are replayed from the final text.
    for (let i = 0; i < text.length; i += CHUNK) {
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
        case 'status': await status(id); return;
        case 'probe': await probe(id); return;
        case 'signOut': {
          const { revoked } = await client.disconnect();
          models = { at: 0, list: [] };
          write({ id, done: true, revoked });
          return;
        }
        case 'cancel': inflight.get(req.target)?.abort(); write({ id, done: true }); return;
        case 'signIn':
        case 'complete':
          inflight.set(id, ctl);
          try { await (req.type === 'signIn' ? signIn(id, ctl) : complete(id, req, ctl)); }
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
