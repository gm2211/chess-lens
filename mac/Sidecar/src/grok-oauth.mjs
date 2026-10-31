// xAI (SuperGrok) sign-in: OAuth 2.0 device-code flow (RFC 8628). Ported from Skim's xai_oauth.rs.
// xAI has no public OAuth client for third-party apps, so this uses the public Grok CLI client id.
// Some SuperGrok tiers get 403 from the API even after sign-in; the API-key path is the fallback.
import { PublicError } from './errors.mjs';

export const CLIENT_ID = 'b1a00492-073a-47ea-816f-4c329264a828';
export const DEVICE_CODE_URL = 'https://auth.x.ai/oauth2/device/code';
export const TOKEN_URL = 'https://auth.x.ai/oauth2/token';
export const SCOPE = 'openid profile email offline_access grok-cli:access api:access';
const DEVICE_GRANT = 'urn:ietf:params:oauth:grant-type:device_code';

const post = async (fetcher, url, form, signal) => {
  let r;
  try {
    r = await fetcher(url, { method: 'POST', redirect: 'error', headers: { Accept: 'application/json', 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(form).toString(), signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(20_000)]) });
  } catch { if (signal?.aborted) throw new PublicError('canceled', 'Canceled.'); throw new PublicError('unavailable', 'Could not reach xAI sign-in.'); }
  return { ok: r.ok, status: r.status, body: await r.json().catch(() => ({})) };
};

function tokens(body, now, previousRefresh) {
  if (typeof body.access_token !== 'string' || !body.access_token) throw new PublicError('auth-failed', 'xAI sign-in returned an unexpected response.');
  const ttl = typeof body.expires_in === 'number' && body.expires_in > 0 ? body.expires_in : 3600;
  const refresh = typeof body.refresh_token === 'string' && body.refresh_token ? body.refresh_token : previousRefresh;
  return { access: body.access_token, ...(refresh ? { refresh } : {}), expiresAt: now() + ttl * 1000 };
}

/** Starts the flow, reports the verification URL and user code through `emit`, polls until approved. */
export async function deviceSignIn({ fetch: fetcher, emit, signal, now = Date.now, sleep = ms => new Promise(r => setTimeout(r, ms)) }) {
  const start = await post(fetcher, DEVICE_CODE_URL, { client_id: CLIENT_ID, scope: SCOPE }, signal);
  const d = start.body;
  if (!start.ok || typeof d.device_code !== 'string' || typeof d.user_code !== 'string' || typeof d.verification_uri !== 'string') throw new PublicError('unavailable', 'xAI sign-in could not be started.');
  emit(typeof d.verification_uri_complete === 'string' ? d.verification_uri_complete : d.verification_uri, { userCode: d.user_code });
  const deadline = now() + Math.min(typeof d.expires_in === 'number' ? d.expires_in : 300, 900) * 1000;
  let wait = Math.max(1, typeof d.interval === 'number' ? d.interval : 5) * 1000;
  while (now() < deadline) {
    await sleep(wait);
    if (signal?.aborted) throw new PublicError('canceled', 'Canceled.');
    const r = await post(fetcher, TOKEN_URL, { grant_type: DEVICE_GRANT, client_id: CLIENT_ID, device_code: d.device_code }, signal);
    if (r.ok) return tokens(r.body, now);
    switch (r.body.error) {
      case 'authorization_pending': continue;
      case 'slow_down': wait += 5000; continue;
      case 'access_denied': case 'authorization_denied': throw new PublicError('auth-failed', 'xAI sign-in was declined.');
      case 'expired_token': throw new PublicError('auth-failed', 'The xAI sign-in code expired. Start again.');
      default: throw new PublicError('auth-failed', `xAI sign-in failed (${r.status}).`);
    }
  }
  throw new PublicError('auth-failed', 'Timed out waiting for xAI sign-in.');
}

export async function refresh({ fetch: fetcher, refreshToken, now = Date.now, signal }) {
  const r = await post(fetcher, TOKEN_URL, { grant_type: 'refresh_token', refresh_token: refreshToken, client_id: CLIENT_ID }, signal);
  if (!r.ok) throw new PublicError(r.status === 400 || r.status === 401 ? 'reconnect-required' : 'unavailable', 'Sign in with Grok again.');
  return tokens(r.body, now, refreshToken);
}
