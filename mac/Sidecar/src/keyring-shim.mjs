// Loads the native Keychain addon from beside the bundle (the package's own loader needs node_modules).
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = dirname(fileURLToPath(import.meta.url));
const addon = { exports: {} };
process.dlopen(addon, process.env.CHESSLENS_KEYRING_ADDON || join(dir, 'keyring.darwin-arm64.node'));
export const AsyncEntry = addon.exports.AsyncEntry;
export const Entry = addon.exports.Entry;
