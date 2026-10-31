// Errors whose message is safe to show the user (never contains a key, token or raw provider payload).
export class PublicError extends Error {
  constructor(code, message) { super(message); this.name = 'PublicError'; this.code = code; }
}
export const SAFE_NAMES = new Set(['ChatGptError', 'ClaudeError', 'PublicError']);
