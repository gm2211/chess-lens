// Provider adapters for the Étude sidecar. Every adapter has the same shape:
//   meta                       {id, name, authKind: "oauth" | "apiKey" | "both", setupText, setupURL, flow}
//   status(signal)             -> {ready, account?, error?}           (no model list; the server adds it)
//   listModels(signal)         -> [{id, name}]                        (always live from the provider)
//   signIn({apiKey, mode, emit, signal}) -> {awaitingCode?}           (emit(url, extra) reports a URL to open)
//   submitCode(code)           paste-code fallback (Claude only)
//   signOut()
//   complete({model, system, prompt, maxTokens, signal, onDelta, onProgress, onThinking}) -> {text, streamed}
// Keys and tokens live only in the Keychain (via `vault`) and never appear in a reply.
import { PublicError, SAFE_NAMES } from './errors.mjs';
import { deviceSignIn, refresh as refreshGrok } from './grok-oauth.mjs';

const hint = (system, max) => max ? `${system}\n\nKeep the answer under about ${max} tokens.`.trim() : system;
const canceled = () => new PublicError('canceled', 'Canceled.');

/** Turns any thrown value into an error that is safe to show. The failure kind comes from byos
 * classifyProviderError; provider text is shown only after redaction, capped at 200 characters. */
export function publicError(e, { secrets = [], who = 'The provider', signal, classify } = {}) {
  if (signal?.aborted || e?.code === 'canceled') return canceled();
  if (e && SAFE_NAMES.has(e.name)) return e;
  const { kind } = classify(e);
  if (kind === 'aborted') return canceled();
  let msg = '';
  if (e instanceof Error && ['Error', 'ProviderRequestError', 'OpenRouterAuthenticationError'].includes(e.name)) {
    msg = String(e.message);
    for (const s of secrets) if (s) msg = msg.split(s).join('[redacted]');
    msg = msg.replace(/\s+/g, ' ').slice(0, 200);
  }
  if (kind === 'auth' || e?.name === 'OpenRouterAuthenticationError') return new PublicError('reconnect-required', msg || `${who} rejected the credential.`);
  if (kind === 'quota') return new PublicError('quota', msg || `${who} usage is limited.`);
  return new PublicError('unavailable', msg || `${who} is unavailable. Try again later.`);
}

export function createProviders({ chatgpt, claude, byos, vault, fetch: fetcher = globalThis.fetch, now = Date.now, sleep }) {
  const out = new Map();

  // --- ChatGPT: the existing chatgpt-local OAuth flow -------------------------------------------------
  out.set('chatgpt', {
    meta: { id: 'chatgpt', name: 'ChatGPT', authKind: 'oauth', flow: 'loopback', setupText: 'Uses your ChatGPT plan. Sign-in tokens stay in your Keychain.', setupURL: '' },
    async status() {
      const s = await chatgpt.status();
      return { ready: !!(s.connected && s.planEnabled), account: s.account?.label ?? null };
    },
    listModels: async signal => (await chatgpt.listModels(signal)).map(m => ({ id: m.id, name: m.name })),
    async signIn({ signal }) {
      const s = await chatgpt.status();
      // Reconnect the saved registration instead of piling up new ones.
      await chatgpt.signIn({ accountId: s.account?.id, enablePlan: true, signal });
      return {};
    },
    signOut: async () => { await chatgpt.disconnect(); },
    async complete({ model, system, prompt, maxTokens, signal, onProgress }) {
      // The kit exposes no token cap, so maxTokens is passed to the model as a length hint.
      const instructions = hint(system, maxTokens);
      const { text } = await chatgpt.generate({ model, input: prompt, ...(instructions ? { instructions } : {}), signal, onProgress });
      return { text, streamed: false };
    },
  });

  // --- Claude Pro/Max subscription: @byos/claude-local ------------------------------------------------
  out.set('claude', {
    meta: { id: 'claude', name: 'Claude', authKind: 'oauth', flow: 'loopback+paste', setupText: 'Uses your Claude Pro or Max plan. Sign-in tokens stay in your Keychain.', setupURL: '' },
    async status() {
      const s = await claude.status();
      return { ready: s.connected, account: s.account?.label ?? null };
    },
    listModels: async signal => (await claude.listModels(signal)).map(m => ({ id: m.id, name: m.name })),
    async signIn({ mode, emit, signal }) {
      if (mode !== 'paste') {
        try { await claude.signIn({ signal }); return {}; }
        catch (e) { if (e?.code !== 'port-in-use') throw e; }
      }
      // Fallback: the console page shows a CODE#STATE string to paste back (submitCode).
      emit(claude.beginPasteSignIn().url);
      return { awaitingCode: true };
    },
    async submitCode(code) { await claude.completePasteSignIn(code); },
    signOut: async () => { await claude.disconnect(); },
    async complete({ model, system, prompt, maxTokens, signal, onDelta }) {
      const { text } = await claude.generate({ model, input: prompt, ...(system ? { instructions: system } : {}), ...(maxTokens ? { maxTokens } : {}), signal, onText: onDelta });
      return { text, streamed: true };
    },
  });

  // --- API-key providers on @byos/providers (Grok also signs in with OAuth) ---------------------------
  function keyed({ id, name, authKind, setupText, setupURL, provider, oauth = false }) {
    const store = vault(id);
    const read = async () => { const raw = await store.get(); try { return raw ? JSON.parse(raw) : null; } catch { return null; } };
    const write = rec => store.set(JSON.stringify(rec));
    /** The bearer credential, refreshing an OAuth access token that is about to expire. */
    async function credential(signal) {
      const rec = await read();
      if (!rec) throw new PublicError('reconnect-required', `Set up ${name} first.`);
      if (rec.kind === 'key') return rec.key;
      if (rec.expiresAt > now() + 60_000) return rec.access;
      if (!rec.refresh) { await store.delete(); throw new PublicError('reconnect-required', `Sign in with ${name} again.`); }
      try {
        const next = await refreshGrok({ fetch: fetcher, refreshToken: rec.refresh, now, signal });
        await write({ kind: 'oauth', ...next });
        return next.access;
      } catch (e) { if (e?.code === 'reconnect-required') await store.delete(); throw e; }
    }
    const wrap = (e, secrets, signal) => publicError(e, { secrets, who: name, signal, classify: byos.classifyProviderError });
    const list = async (key, signal) => (await provider.listModels(key, signal)).map(m => ({ id: m.id, name: m.name }));
    return {
      meta: { id, name, authKind, flow: oauth ? 'device' : '', setupText, setupURL },
      async status() {
        const rec = await read();
        return { ready: !!rec, account: rec ? (rec.kind === 'oauth' ? `${name} account` : 'API key') : null };
      },
      async listModels(signal) {
        const key = await credential(signal);
        try { return await list(key, signal); } catch (e) { throw wrap(e, [key], signal); }
      },
      async signIn({ apiKey, emit, signal }) {
        if (oauth && !apiKey) {
          const t = await deviceSignIn({ fetch: fetcher, emit, signal, now, ...(sleep ? { sleep } : {}) });
          await write({ kind: 'oauth', ...t });
          return {};
        }
        const key = typeof apiKey === 'string' ? apiKey.trim() : '';
        if (!key || key.length > 512 || /\s/.test(key)) throw new PublicError('bad-request', 'Paste a valid API key.');
        // A cheap authenticated call proves the key works before it is stored.
        let models;
        try { models = await list(key, signal); } catch (e) {
          const err = wrap(e, [key], signal);
          throw err.code === 'canceled' ? err : new PublicError('auth-failed', `${name} did not accept that key. ${err.message}`.slice(0, 240));
        }
        if (!models.length) throw new PublicError('auth-failed', `${name} accepted the key but offers no chat models.`);
        await write({ kind: 'key', key });
        return {};
      },
      async signOut() { await store.delete(); },
      async complete({ model, system, prompt, maxTokens, signal, onDelta, onThinking }) {
        const key = await credential(signal);
        const sys = system ? (id === 'claudeAPI' ? system : hint(system, maxTokens)) : hint('', maxTokens);
        let text = '';
        try {
          for await (const ev of provider.stream(key, { model, signal, messages: [...(sys ? [{ role: 'system', content: sys }] : []), { role: 'user', content: prompt }] })) {
            if (ev.type === 'text') { text += ev.text; onDelta?.(ev.text); }
            else if (ev.type === 'reasoning') onThinking?.();   // the model is working; the app counts it as activity
          }
        } catch (e) { throw wrap(e, [key], signal); }
        return { text, streamed: true };
      },
    };
  }

  const add = a => out.set(a.meta.id, a);
  add(keyed({ id: 'claudeAPI', name: 'Claude API', authKind: 'apiKey', setupText: 'Create a key in Claude Console. Max and Team plans include monthly API credits.', setupURL: 'https://platform.claude.com/settings/keys', provider: byos.claude() }));
  add(keyed({ id: 'openrouter', name: 'OpenRouter', authKind: 'apiKey', setupText: 'Create a key at openrouter.ai. One key reaches many models.', setupURL: 'https://openrouter.ai/settings/keys', provider: byos.openrouter({ appTitle: 'Étude', referer: 'https://github.com/gm2211/chess-lens' }) }));
  add(keyed({ id: 'grok', name: 'Grok', authKind: 'both', oauth: true, setupText: 'Sign in with SuperGrok, or paste an xAI API key from console.x.ai.', setupURL: 'https://console.x.ai', provider: byos.grok({ deviceCodeViaSite: false }) }));
  add(keyed({ id: 'groq', name: 'Groq', authKind: 'apiKey', setupText: 'Create a key at console.groq.com.', setupURL: 'https://console.groq.com/keys', provider: byos.groq() }));
  add(keyed({ id: 'huggingface', name: 'Hugging Face', authKind: 'apiKey', setupText: 'Create a fine-grained access token with Inference Providers permission.', setupURL: 'https://huggingface.co/settings/tokens', provider: byos.huggingface() }));
  return out;
}
