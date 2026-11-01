#!/usr/bin/env node
// Re-vendors BYOS into mac/Sidecar/byos from an exact commit. Never hand-edit that directory.
// Run it under the sandbox (the exporter executes code from the BYOS checkout):
//   ~/.claude/bin/safe-run.sh -C . -- node scripts/sync-byos.mjs /path/to/byos <full-40-character-commit-sha>
// The SHA is required and must be a full commit id; `main` and abbreviations are refused.
// Mirrors the "chess-lens" entry in BYOS's consumers.json.
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'mac', 'Sidecar', 'byos');
const [sourceArgument, revisionArgument, ...extra] = process.argv.slice(2);
if (!sourceArgument || !revisionArgument || extra.length || !/^[0-9a-f]{40}$/i.test(revisionArgument) || /[\r\n\0]/.test(sourceArgument) || sourceArgument.includes('://')) {
  console.error('Usage: node scripts/sync-byos.mjs /path/to/byos <full-40-character-commit-sha>');
  process.exitCode = 1;
} else {
  let temporary;
  try {
    const source = await realpath(sourceArgument);
    const revision = revisionArgument.toLowerCase();
    const commit = execFileSync('git', ['-C', source, 'rev-parse', '--verify', `${revision}^{commit}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
    if (commit !== revision) throw Error('Revision is not an exact commit.');
    // Execute the exporter from the same immutable revision as the selected sources.
    const exporter = execFileSync('git', ['-C', source, 'show', `${revision}:scripts/vendor.mjs`], { stdio: ['ignore', 'pipe', 'pipe'] });
    temporary = await mkdtemp(join(tmpdir(), 'chess-lens-byos-sync-'));
    const script = join(temporary, 'vendor.mjs');
    await writeFile(script, exporter, { mode: 0o600 });
    execFileSync(process.execPath, [script, '--source', source, '--ref', revision, '--out', out, '--mode', 'packages', '--packages', 'chatgpt-local,claude-local,core,providers', '--name-prefix', 'byos-', '--revision', join(out, 'BYOS_REVISION'), '--engine', 'omit'], { cwd: root, stdio: 'inherit' });
    const recorded = await readFile(join(out, 'BYOS_REVISION'), 'utf8');
    if (!recorded.includes(revision)) throw Error('Exporter did not record the requested revision.');
    console.log('BYOS synced. Run the sidecar tests and build, then review and commit mac/Sidecar/byos.');
  } catch (e) {
    console.error('BYOS sync failed. Use a local BYOS Git checkout containing the exact commit and its scripts/vendor.mjs exporter.');
    console.error(String(e?.message ?? e));
    process.exitCode = 1;
  } finally { if (temporary) await rm(temporary, { recursive: true, force: true }); }
}
