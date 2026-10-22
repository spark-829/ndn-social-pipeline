// Supabase Edge Function: daily snapshot of every authorized TikTok account (official TikTok API for Business).
// Called by pg_cron (ndn-tiktok-api-daily) or by hand:
//   POST /functions/v1/tiktok-business-snapshot?by=manual[&force=1]   header x-cron-secret: <vault ndn_cron_secret>
//
// For each account in raw.tiktok_api_tokens:
//   1. refresh the access token if it expires within the next hour
//   2. /business/get/        -> account info (followers etc.)      saved untouched in raw.tiktok_api_responses
//   3. /business/video/list/ -> every video, 20 per page (cursor)  saved untouched, one row per page
//   4. one row in raw.tiktok_api_runs
// Idempotent: an account already done today is skipped unless ?force=1.
//
// Field lists are env vars so they can be changed without redeploying code. If TikTok rejects a field,
// the error message is saved in the response row and the run row; drop the field and run again with force=1.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";
import { apiGet, listAllVideos, refreshToken, TikTokApiError, type TikTokEnvelope } from "../_shared/tiktok_business.ts";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const APP_ID = Deno.env.get("TIKTOK_APP_ID") ?? "";
const APP_SECRET = Deno.env.get("TIKTOK_APP_SECRET") ?? "";

const fieldList = (name: string, fallback: string[]) => {
  const v = Deno.env.get(name);
  if (!v) return fallback;
  try { return JSON.parse(v); } catch { return v.split(",").map((s) => s.trim()).filter(Boolean); }
};
const ACCOUNT_FIELDS = fieldList("TIKTOK_ACCOUNT_FIELDS",
  ["username", "display_name", "profile_image", "followers_count", "is_business_account"]);
const VIDEO_FIELDS = fieldList("TIKTOK_VIDEO_FIELDS",
  ["item_id", "create_time", "caption", "share_url", "thumbnail_url", "video_duration",
   "video_views", "likes", "comments", "shares", "reach"]);

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) return new Response("unauthorized", { status: 401 });
  if (!APP_ID || !APP_SECRET) return new Response("TIKTOK_APP_ID / TIKTOK_APP_SECRET missing", { status: 500 });

  const url = new URL(req.url);
  const force = url.searchParams.get("force") === "1";
  const by = url.searchParams.get("by") ?? "manual";
  const today = new Date().toISOString().slice(0, 10);

  const accounts = await sql`select * from raw.tiktok_api_tokens where status <> 'revoked' order by authorized_at`;
  if (accounts.length === 0) return Response.json({ status: "no_accounts", hint: "nobody has authorized yet" });

  const results: unknown[] = [];
  for (const acct of accounts) {
    const openId: string = acct.open_id;

    if (!force) {
      const done = await sql`select 1 from raw.tiktok_api_runs
                             where snapshot_date = ${today} and open_id = ${openId} and status = 'ok'`;
      if (done.length) { results.push({ open_id: openId, username: acct.username, status: "already_done" }); continue; }
    }

    // 1) token: refresh if it expires within an hour
    let accessToken: string = acct.access_token;
    if (new Date(acct.access_expires_at).getTime() < Date.now() + 3600_000) {
      try {
        const t = await refreshToken(APP_ID, APP_SECRET, acct.refresh_token);
        accessToken = t.access_token;
        await sql`update raw.tiktok_api_tokens set access_token = ${t.access_token}, refresh_token = ${t.refresh_token},
                    scope = coalesce(${t.scope}, scope), access_expires_at = ${t.access_expires_at},
                    refresh_expires_at = coalesce(${t.refresh_expires_at}, refresh_expires_at),
                    updated_at = now(), status = 'active', last_error = null
                  where open_id = ${openId}`;
      } catch (err) {
        const msg = err instanceof TikTokApiError ? err.message : String(err);
        await sql`update raw.tiktok_api_tokens set status = 'refresh_failed', last_error = ${msg}, updated_at = now()
                  where open_id = ${openId}`;
        await saveRun(today, openId, acct.username, "error", null, null, null, `token refresh failed: ${msg}`, by);
        results.push({ open_id: openId, username: acct.username, status: "error", error: msg,
                       hint: "the owner may need to open the invite link again" });
        continue;
      }
    }

    const stamp = new Date().toISOString();
    const save = (endpoint: string, page: number, fields: string[], env: TikTokEnvelope) => sql`
      insert into raw.tiktok_api_responses (snapshot_date, open_id, endpoint, page, extracted_at, request_fields, payload)
      values (${today}, ${openId}, ${endpoint}, ${page}, ${stamp}, ${sql.json(fields)}, ${sql.json(env as any)})
      on conflict (snapshot_date, open_id, endpoint, page)
      do update set extracted_at = excluded.extracted_at, request_fields = excluded.request_fields,
                    payload = excluded.payload, loaded_at = now()`;

    const errors: string[] = [];
    let followers: number | null = null;
    let username: string | null = acct.username;

    // 2) account
    try {
      const env = await apiGet("business/get", accessToken, { business_id: openId, fields: JSON.stringify(ACCOUNT_FIELDS) });
      await save("business/get", 1, ACCOUNT_FIELDS, env);
      if (env.code === 0) {
        followers = env.data?.followers_count ?? null;
        username = env.data?.username ?? username;
      } else errors.push(`business/get ${env.code} ${env.message}`);
    } catch (err) { errors.push(String(err instanceof Error ? err.message : err)); }

    // 3) videos (a fresh force run first clears today's pages so a shorter list leaves no stale pages)
    let videos = 0, pages = 0;
    try {
      if (force) await sql`delete from raw.tiktok_api_responses
                           where snapshot_date = ${today} and open_id = ${openId} and endpoint = 'business/video/list'`;
      const r = await listAllVideos(accessToken, openId, VIDEO_FIELDS,
        async (page, env) => { await save("business/video/list", page, VIDEO_FIELDS, env); });
      videos = r.videos; pages = r.pages;
      if (r.error) errors.push(r.error);
    } catch (err) { errors.push(String(err instanceof Error ? err.message : err)); }

    const status = errors.length ? "error" : "ok";
    await saveRun(today, openId, username, status, videos, pages, followers, errors.join(" | ") || null, by);
    results.push({ open_id: openId, username, status, videos, pages, followers, errors });
  }

  return Response.json({ snapshot_date: today, results });
});

function saveRun(day: string, openId: string, username: string | null, status: string,
                 videos: number | null, pages: number | null, followers: number | null,
                 error: string | null, by: string) {
  return sql`
    insert into raw.tiktok_api_runs (snapshot_date, open_id, username, status, videos, pages, followers, error, triggered_by, finished_at)
    values (${day}, ${openId}, ${username}, ${status}, ${videos}, ${pages}, ${followers}, ${error}, ${by}, now())
    on conflict (snapshot_date, open_id) do update set
      username = excluded.username, status = excluded.status, videos = excluded.videos, pages = excluded.pages,
      followers = excluded.followers, error = excluded.error, triggered_by = excluded.triggered_by, finished_at = now()`;
}
