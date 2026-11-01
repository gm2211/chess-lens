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

/** GrokError (fixed, safe text from @byos/grok-local) -> PublicError. */
const GROK_CODES = { 'reconnect-required': 'reconnect-required', canceled: 'canceled', declined: 'auth-failed', expired: 'auth-failed', 'auth-failed': 'auth-failed', 'invalid-response': 'auth-failed', 'storage-unavailable': 'unavailable', unavailable: 'unavailable', busy: 'unavailable' };
export const grokPublicError = e => new PublicError(GROK_CODES[e?.code] ?? 'unavailable', e instanceof Error ? e.message : 'Grok is unavailable.');

/** Wraps a provider error that must not be retried by grok.run (it has already streamed output). */
class Streamed extends Error { constructor(cause) { super(cause?.message); this.name = cause?.name ?? 'Error'; this.cause = cause; } }

/** One-time startup migration: the old sidecar kept Grok OAuth tokens in the `grok` vault item; they now live in grok-local. */
export async function migrateGrokTokens({ grok, vault }) {
  const store = vault('grok');
  let rec;
  try { const raw = await store.get(); rec = raw ? JSON.parse(raw) : null; } catch { return false; }
  if (rec?.kind !== 'oauth') return false;
  if (typeof rec.access === 'string' && rec.access && typeof rec.expiresAt === 'number') {
    await grok.importTokens({ access: rec.access, ...(typeof rec.refresh === 'string' && rec.refresh ? { refresh: rec.refresh } : {}), expiresAt: rec.expiresAt });
  }
  await store.delete();
  return true;
}

export function createProviders({ chatgpt, claude, grok, byos, vault }) {
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
    /** Runs fn(token) with the stored API key, or (OAuth providers) with a Grok subscription token that
     * grok.run refreshes and retries once on 401. Errors come out as PublicError. `secrets` lists tokens to redact. */
    async function withCredential(signal, fn) {
      const rec = await read();
      if (rec?.kind === 'key') {
        try { return await fn(rec.key); } catch (e) { throw wrap(e instanceof Streamed ? e.cause : e, [rec.key], signal); }
      }
      if (!oauth) throw new PublicError('reconnect-required', `Set up ${name} first.`);
      const seen = [];
      try { return await grok.run(signal, tok => { seen.push(tok); return fn(tok); }); }
      catch (e) { throw wrap(e instanceof Streamed ? e.cause : e, seen, signal); }
    }
    const wrap = (e, secrets, signal) => e?.name === 'GrokError' ? grokPublicError(e) : publicError(e, { secrets, who: name, signal, classify: byos.classifyProviderError });
    const list = async (key, signal) => (await provider.listModels(key, signal)).map(m => ({ id: m.id, name: m.name }));
    return {
      meta: { id, name, authKind, flow: oauth ? 'device' : '', setupText, setupURL },
      async status() {
        const rec = await read();
        if (rec?.kind === 'key') return { ready: true, account: 'API key' };
        if (!oauth) return { ready: false, account: null };
        try { const s = await grok.status(); return { ready: s.connected, account: s.connected ? (s.account?.label ?? `${name} account`) : null }; }
        catch (e) { throw grokPublicError(e); }
      },
      listModels: signal => withCredential(signal, tok => list(tok, signal)),
      async signIn({ apiKey, emit, signal }) {
        if (oauth && !apiKey) {
          try { await grok.signIn({ onCode: ({ verificationUrl, userCode }) => { emit(verificationUrl, { userCode }); }, signal }); }
          catch (e) { throw e?.name === 'GrokError' ? grokPublicError(e) : e; }
          await store.delete();   // the subscription replaces any pasted key
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
        if (oauth) { try { await grok.disconnect(); } catch { /* a stale sign-in is harmless beside a key */ } }
        return {};
      },
      async signOut() {
        await store.delete();
        if (oauth) { try { await grok.disconnect(); } catch (e) { throw grokPublicError(e); } }
      },
      async complete({ model, system, prompt, maxTokens, signal, onDelta, onThinking }) {
        const sys = system ? (id === 'claudeAPI' ? system : hint(system, maxTokens)) : hint('', maxTokens);
        let text = '';
        await withCredential(signal, async key => {
          text = '';
          let started = false;
          try {
            for await (const ev of provider.stream(key, { model, signal, messages: [...(sys ? [{ role: 'system', content: sys }] : []), { role: 'user', content: prompt }] })) {
              if (ev.type === 'text') { started = true; text += ev.text; onDelta?.(ev.text); }
              else if (ev.type === 'reasoning') onThinking?.();   // the model is working; the app counts it as activity
            }
          } catch (e) { throw started ? new Streamed(e) : e; }   // grok.run retries a 401 only before the first delta
        });
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
