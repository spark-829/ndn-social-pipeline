// Supabase Edge Function: sign-in link + OAuth callback for the TikTok API for Business.
//
//   GET ?invite=<code>          -> sends the account owner to TikTok's sign-in/consent page
//   GET ?code=...&state=...     -> TikTok sends them back here; we swap the code for tokens and save them
//   GET ?error=...              -> they clicked Cancel (or TikTok refused); show the reason
//
// Deploy with JWT verification OFF (a browser redirect carries no Supabase JWT):
//   supabase functions deploy tiktok-oauth-callback --no-verify-jwt
// Secrets (Edge Function secrets): TIKTOK_APP_ID, TIKTOK_APP_SECRET
// Optional: TIKTOK_AUTH_URL (the portal's ready-made "TikTok account holder authorization URL"),
//           TIKTOK_SCOPES, TIKTOK_REDIRECT_URI (must match the portal exactly)
// Vault: tiktok_oauth_invite (so random visitors can't start the flow)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";
import { apiGet, buildAuthorizeUrl, exchangeCode, TikTokApiError } from "../_shared/tiktok_business.ts";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const APP_ID = Deno.env.get("TIKTOK_APP_ID") ?? "";
const APP_SECRET = Deno.env.get("TIKTOK_APP_SECRET") ?? "";
const PORTAL_AUTH_URL = Deno.env.get("TIKTOK_AUTH_URL") || undefined;
const SCOPES = Deno.env.get("TIKTOK_SCOPES") ?? "user.info.basic,user.insights,video.list,video.insights";
const REDIRECT_URI = Deno.env.get("TIKTOK_REDIRECT_URI") ??
  `${Deno.env.get("SUPABASE_URL")}/functions/v1/tiktok-oauth-callback`;

function page(title: string, body: string, status = 200): Response {
  const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${esc(title)}</title>
<body style="font-family:system-ui,sans-serif;max-width:560px;margin:15vh auto;padding:0 16px;line-height:1.5;color:#222">
<h2>${esc(title)}</h2><p>${esc(body)}</p>
<p style="color:#777;font-size:13px">NDN social analytics · read-only access · you can revoke it anytime in TikTok settings.</p></body>`;
  return new Response(html, { status, headers: { "Content-Type": "text/html; charset=utf-8" } });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const p = url.searchParams;

  if (!APP_ID || !APP_SECRET) return page("Not set up yet", "TIKTOK_APP_ID / TIKTOK_APP_SECRET are missing.", 500);

  // 1) Owner declined, or TikTok returned an error
  if (p.has("error")) {
    return page("TikTok access not granted", `${p.get("error")}: ${p.get("error_description") ?? ""}`, 400);
  }

  // 2) Coming back from TikTok with a one-time code
  const code = p.get("code") ?? p.get("auth_code");
  if (code) {
    const state = p.get("state") ?? "";
    const used = await sql`
      delete from raw.tiktok_api_oauth_state
      where state = ${state} and created_at > now() - interval '15 minutes'
      returning state`;
    if (used.length === 0) {
      return page("Link expired", "This sign-in link is old or was already used. Open the invite link again.", 400);
    }
    try {
      const t = await exchangeCode(APP_ID, APP_SECRET, code, REDIRECT_URI);
      let username: string | null = null, display: string | null = null;
      try {
        const acct = await apiGet("business/get", t.access_token, {
          business_id: t.open_id,
          fields: JSON.stringify(["username", "display_name"]),
        });
        username = acct.data?.username ?? null;
        display = acct.data?.display_name ?? null;
      } catch { /* name is nice-to-have; tokens are what matter */ }

      await sql`
        insert into raw.tiktok_api_tokens
          (open_id, username, display_name, access_token, refresh_token, scope,
           access_expires_at, refresh_expires_at, authorized_at, updated_at, status, last_error)
        values (${t.open_id}, ${username}, ${display}, ${t.access_token}, ${t.refresh_token}, ${t.scope},
                ${t.access_expires_at}, ${t.refresh_expires_at}, now(), now(), 'active', null)
        on conflict (open_id) do update set
          username = coalesce(excluded.username, raw.tiktok_api_tokens.username),
          display_name = coalesce(excluded.display_name, raw.tiktok_api_tokens.display_name),
          access_token = excluded.access_token, refresh_token = excluded.refresh_token,
          scope = excluded.scope, access_expires_at = excluded.access_expires_at,
          refresh_expires_at = excluded.refresh_expires_at, authorized_at = now(),
          updated_at = now(), status = 'active', last_error = null`;

      return page("Connected", `TikTok account ${username ? "@" + username : t.open_id} is connected. You can close this tab.`);
    } catch (err) {
      const msg = err instanceof TikTokApiError ? err.message : String(err);
      return page("Could not finish connecting", msg, 502);
    }
  }

  // 3) Start: invite link -> TikTok consent page
  const invite = p.get("invite");
  if (invite) {
    const [row] = await sql`
      select decrypted_secret as secret from vault.decrypted_secrets where name = 'tiktok_oauth_invite'`;
    if (!row?.secret || invite !== row.secret) return page("Invalid invite", "This invite link is not valid.", 403);

    const state = crypto.randomUUID().replaceAll("-", "");
    await sql`delete from raw.tiktok_api_oauth_state where created_at < now() - interval '1 day'`;
    await sql`insert into raw.tiktok_api_oauth_state (state) values (${state})`;
    const target = buildAuthorizeUrl({ appId: APP_ID, redirectUri: REDIRECT_URI, scopes: SCOPES, state, portalUrl: PORTAL_AUTH_URL });
    return Response.redirect(target, 302);
  }

  return page("Nothing to do", "Open the invite link you were sent to connect a TikTok account.", 400);
});
