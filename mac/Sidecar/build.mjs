// Bundles src/main.mjs + the vendored @byos packages (chatgpt-local, claude-local, grok-local, providers; TypeScript source) + jose into out/sidecar.mjs
// and copies the @napi-rs/keyring native addon next to it. Run through mac/scripts/build-sidecar.sh.
import { build } from 'esbuild';
import { copyFileSync, mkdirSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
rmSync(here('out'), { recursive: true, force: true });
mkdirSync(here('out'), { recursive: true });

await build({
  entryPoints: [here('src/main.mjs')],
  outfile: here('out/sidecar.mjs'),
  bundle: true, platform: 'node', format: 'esm', target: 'node24', legalComments: 'none',
  alias: {
    '@byos/chatgpt-local': here('byos/byos-chatgpt-local/src/index.ts'),
    '@byos/claude-local': here('byos/byos-claude-local/src/index.ts'),
    '@byos/grok-local': here('byos/byos-grok-local/src/index.ts'),
    '@byos/providers': here('byos/byos-providers/src/index.ts'),
    '@byos/core': here('byos/byos-core/src/index.ts'),
  },
  // The package's own keyring loader needs node_modules; the shim dlopen()s the addon beside the bundle instead.
  plugins: [{
    name: 'keyring-shim',
    setup(b) { b.onResolve({ filter: /^@napi-rs\/keyring$/ }, () => ({ path: here('src/keyring-shim.mjs') })); },
  }],
});
copyFileSync(here('node_modules/@napi-rs/keyring-darwin-arm64/keyring.darwin-arm64.node'), here('out/keyring.darwin-arm64.node'));
console.log('sidecar bundle written to out/');
