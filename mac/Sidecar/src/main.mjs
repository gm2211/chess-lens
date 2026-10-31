// Chess Lens LLM sidecar entry point: newline-delimited JSON on stdin/stdout. Exits when stdin closes.
import { createInterface } from 'node:readline';
import { createChatGptClient } from '@byos/chatgpt-local';
import { createClaudeClient } from '@byos/claude-local';
import * as byos from '@byos/providers';
import { AsyncEntry } from '@napi-rs/keyring';
import { createHandler } from './server.mjs';
import { createProviders } from './providers.mjs';

// stdout is the protocol channel; keep everything else off it.
const write = (obj) => { try { process.stdout.write(JSON.stringify(obj) + '\n'); } catch { /* parent gone */ } };
process.stdout.on('error', () => process.exit(0));
console.log = console.info = console.warn = console.error = () => {};

const urlSink = { fn: null };
const common = {
  appName: 'Chess Lens',
  namespace: 'chesslens',
  ...(process.env.CHESSLENS_LOCK_DIR ? { storageDirectory: process.env.CHESSLENS_LOCK_DIR } : {}),
  // The Swift side opens the URL (NSWorkspace); the sidecar only reports it (see signIn in server.mjs).
  openBrowser: (url) => { urlSink.fn?.(url); },
};
const chatgpt = createChatGptClient(common);
const claude = createClaudeClient(common);

// One Keychain item per key provider; the Swift side never sees its contents.
const vault = (provider) => {
  const entry = () => new AsyncEntry(`app.chesslens.ai.${provider}`, 'credential');
  return {
    get: async () => (await entry().getPassword()) ?? null,
    set: async (value) => { await entry().setPassword(value); },
    delete: async () => { try { await entry().deletePassword(); } catch { /* nothing stored */ } },
  };
};

const providers = createProviders({
  chatgpt, claude, vault,
  byos: { claude: byos.claude, openrouter: byos.openrouter, grok: byos.grok, groq: byos.groq, huggingface: byos.huggingface, isClaudeSubscriptionCredential: byos.isClaudeSubscriptionCredential },
});

const handle = createHandler({ providers, write, urlSink, probeStore: () => new AsyncEntry('app.chesslens.sidecar.probe', 'probe') });

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let req;
  try { req = JSON.parse(line); } catch { write({ id: null, error: { code: 'bad-request', message: 'Invalid JSON.' } }); return; }
  void handle(req);
});
rl.on('close', () => process.exit(0));
