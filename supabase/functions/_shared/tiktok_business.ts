// Shared helpers for the official TikTok API for Business ("TikTok accounts" scope).
// Used by tiktok-oauth-callback and tiktok-business-snapshot.
//
// Every TikTok Business API response looks like {code, message, request_id, data}.
// code 0 = success; anything else is an error even when the HTTP status is 200.

export const API_BASE = "https://business-api.tiktok.com/open_api/v1.3";
export const AUTHORIZE_URL = "https://www.tiktok.com/v2/auth/authorize/";

export type TikTokEnvelope<T = any> = { code: number; message: string; request_id?: string; data?: T };

export type TokenSet = {
  open_id: string;
  access_token: string;
  refresh_token: string;
  scope: string | null;
  access_expires_at: Date;
  refresh_expires_at: Date | null;
};

export class TikTokApiError extends Error {
  constructor(public where: string, public code: number | string, message: string) {
    super(`${where}: ${code} ${message}`);
  }
}

type Fetch = typeof fetch;

async function postJson(url: string, body: unknown, f: Fetch): Promise<TikTokEnvelope> {
  const resp = await f(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await resp.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new TikTokApiError(url, resp.status, text.slice(0, 300));
  }
}

function toTokenSet(d: any, now = new Date()): TokenSet {
  if (!d?.access_token || !d?.refresh_token || !d?.open_id) {
    throw new TikTokApiError("token", "bad_response", "missing access_token / refresh_token / open_id");
  }
  const secs = (v: unknown, fallback: number) => (Number.isFinite(Number(v)) ? Number(v) : fallback);
  return {
    open_id: String(d.open_id),
    access_token: d.access_token,
    refresh_token: d.refresh_token,
    scope: d.scope ?? null,
    access_expires_at: new Date(now.getTime() + secs(d.expires_in, 86400) * 1000),
    refresh_expires_at: d.refresh_token_expires_in != null
      ? new Date(now.getTime() + secs(d.refresh_token_expires_in, 0) * 1000)
      : null,
  };
}

/** Swap the one-time auth_code from the redirect for an access + refresh token. */
export async function exchangeCode(
  appId: string, appSecret: string, authCode: string, redirectUri: string, f: Fetch = fetch,
): Promise<TokenSet> {
  const env = await postJson(`${API_BASE}/tt_user/oauth2/token/`, {
    client_id: appId,
    client_secret: appSecret,
    grant_type: "authorization_code",
    auth_code: authCode,
    redirect_uri: redirectUri,
  }, f);
  if (env.code !== 0) throw new TikTokApiError("token", env.code, env.message);
  return toTokenSet(env.data);
}

/** Get a fresh access token with the long-lived refresh token. */
export async function refreshToken(
  appId: string, appSecret: string, refresh: string, f: Fetch = fetch,
): Promise<TokenSet> {
  const env = await postJson(`${API_BASE}/tt_user/oauth2/refresh_token/`, {
    client_id: appId,
    client_secret: appSecret,
    grant_type: "refresh_token",
    refresh_token: refresh,
  }, f);
  if (env.code !== 0) throw new TikTokApiError("refresh", env.code, env.message);
  return toTokenSet(env.data);
}

/** GET a Business API endpoint. Returns the full envelope untouched (we store it as raw). */
export async function apiGet(
  path: string, accessToken: string, params: Record<string, string | number>, f: Fetch = fetch,
): Promise<TikTokEnvelope> {
  const url = new URL(`${API_BASE}/${path.replace(/^\/|\/$/g, "")}/`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
  for (let attempt = 1; attempt <= 3; attempt++) {
    const resp = await f(url, { headers: { "Access-Token": accessToken } });
    if (resp.status === 429 || resp.status >= 500) {
      if (attempt === 3) throw new TikTokApiError(path, resp.status, "server busy, gave up after 3 tries");
      await new Promise((r) => setTimeout(r, 2000 * attempt));
      continue;
    }
    const text = await resp.text();
    try {
      return JSON.parse(text);
    } catch {
      throw new TikTokApiError(path, resp.status, text.slice(0, 300));
    }
  }
  throw new TikTokApiError(path, "unreachable", "");
}

/** Walk /business/video/list/ with its cursor. Calls onPage for every page (to save it raw). */
export async function listAllVideos(
  accessToken: string, businessId: string, fields: string[],
  onPage: (page: number, env: TikTokEnvelope) => Promise<void>,
  f: Fetch = fetch, maxPages = 200,
): Promise<{ videos: number; pages: number; error: string | null }> {
  let cursor: string | number | undefined;
  let videos = 0;
  for (let page = 1; page <= maxPages; page++) {
    const params: Record<string, string | number> = {
      business_id: businessId,
      fields: JSON.stringify(fields),
      max_count: 20,
    };
    if (cursor !== undefined) params.cursor = cursor;
    const env = await apiGet("business/video/list", accessToken, params, f);
    await onPage(page, env);
    if (env.code !== 0) return { videos, pages: page, error: `video/list ${env.code} ${env.message}` };
    videos += env.data?.videos?.length ?? 0;
    if (!env.data?.has_more || env.data?.cursor === undefined || env.data?.cursor === cursor) {
      return { videos, pages: page, error: null };
    }
    cursor = env.data.cursor;
  }
  return { videos, pages: maxPages, error: `stopped at ${maxPages} pages` };
}

/** Build the TikTok sign-in URL. If the portal gave us a ready-made URL, use it and only set state. */
export function buildAuthorizeUrl(
  opts: { appId: string; redirectUri: string; scopes: string; state: string; portalUrl?: string },
): string {
  if (opts.portalUrl) {
    const u = new URL(opts.portalUrl);
    u.searchParams.set("state", opts.state);
    if (!u.searchParams.has("redirect_uri")) u.searchParams.set("redirect_uri", opts.redirectUri);
    return u.toString();
  }
  const u = new URL(AUTHORIZE_URL);
  u.searchParams.set("client_key", opts.appId);
  u.searchParams.set("scope", opts.scopes);
  u.searchParams.set("response_type", "code");
  u.searchParams.set("redirect_uri", opts.redirectUri);
  u.searchParams.set("state", opts.state);
  return u.toString();
}
