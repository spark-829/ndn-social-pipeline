// Supabase Edge Function: daily Instagram snapshot for Nine Degrees North.
// Calls Meta's Business Discovery API (public data of another Business account)
// and writes every response untouched into raw.instagram_responses (Extract + Load).
//
// Called once a day by pg_cron. Idempotent: if today's run exists, it returns early.
//
// Secrets: IG_ACCESS_TOKEN (non-expiring Page token), IG_USER_ID (Vic's own IG Business
//          account id; Business Discovery is always asked "through" your own account).
//          Caller must send header x-cron-secret matching vault secret 'ndn_cron_secret'.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const API = "https://graph.facebook.com/v23.0";
const NDN_USERNAME = "ninedegreesnorthrecords";
const PAGE_SIZE = 100;                 // largest page that worked in testing (2026-10-16)
const MAX_PAGES = 50;                  // safety stop: 5,000 posts
const MAX_RETRIES = 4;
const MIN_COVERAGE = 0.95;             // fail if fewer posts come back than the profile shows
const PROFILE = "username,name,biography,website,followers_count,follows_count,media_count";
// view_count = Reels only (paid + organic; since Apr 2026 also Facebook views of crossposted reels).
// reposts_count and the total_* counts (Instagram + crossposted Facebook) are public since Apr 2026.
// Tested 2026-10-21: all four come back for NDN; comments, collaborators, shares, saves are refused.
const MEDIA = "id,caption,media_type,media_product_type,timestamp,permalink,like_count,comments_count," +
              "view_count,reposts_count,total_like_count,total_comments_count";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });

const redact = (s: string, token: string) => s.split(token).join("REDACTED");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function callApi(igUserId: string, fields: string, token: string) {
  const url = `${API}/${igUserId}?` + new URLSearchParams({ fields, access_token: token });
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    const resp = await fetch(url);
    const text = await resp.text();
    if (resp.status === 200) return { url: redact(url, token), payload: JSON.parse(text) };
    // 4/17/32/613 = rate limits; 1/2 = temporary Meta errors. Anything else (e.g. 190 expired token) fails now.
    const code = (() => { try { return JSON.parse(text).error?.code; } catch { return undefined; } })();
    if ((resp.status >= 500 || [1, 2, 4, 17, 32, 613].includes(code)) && attempt < MAX_RETRIES) {
      await sleep(2 ** attempt * 1000);
      continue;
    }
    throw new Error(`HTTP ${resp.status}: ${redact(text.slice(0, 300), token)}`);
  }
  throw new Error("unreachable");
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const triggeredBy = new URL(req.url).searchParams.get("by") ?? "manual";
  const token = (Deno.env.get("IG_ACCESS_TOKEN") ?? "").trim();
  const igUserId = (Deno.env.get("IG_USER_ID") ?? "").trim();
  if (!token || !igUserId) return new Response("IG_ACCESS_TOKEN / IG_USER_ID secret missing", { status: 500 });

  const now = new Date();
  const snapshotDate = now.toISOString().slice(0, 10);
  const stamp = now.toISOString().replace(/\.\d{3}Z$/, "+00:00");

  const done = await sql`select 1 from raw.instagram_runs where snapshot_date = ${snapshotDate}`;
  if (done.length) return Response.json({ status: "already_done", snapshot_date: snapshotDate });

  try {
    const files: { name: string; url: string; payload: any }[] = [];
    let after: string | undefined, posts = 0, profile: any;
    do {
      const media = `media${after ? `.after(${after})` : ""}.limit(${PAGE_SIZE}){${MEDIA}}`;
      // Page 1 also carries the profile fields, so one call gets both.
      const fields = `business_discovery.username(${NDN_USERNAME}){${files.length ? "" : PROFILE + ","}${media}}`;
      const res = await callApi(igUserId, fields, token);
      const bd = res.payload.business_discovery;
      if (!bd) throw new Error("no business_discovery in response");
      profile ??= bd;
      files.push({ name: `media_${String(files.length + 1).padStart(3, "0")}`, ...res });
      const got = bd.media?.data?.length ?? 0;
      posts += got;
      // Business Discovery gives a cursor but no 'next' link; a short page means the end.
      after = got === PAGE_SIZE ? bd.media?.paging?.cursors?.after : undefined;
    } while (after && files.length < MAX_PAGES);

    const expected = Number(profile.media_count ?? 0);
    if (expected && posts < MIN_COVERAGE * expected) {
      throw new Error(`got ${posts} posts but the profile shows ${expected}`);
    }

    await sql.begin(async (tx) => {
      for (const f of files) {
        await tx`
          insert into raw.instagram_responses (snapshot_date, file_name, extracted_at, request_url, payload)
          values (${snapshotDate}, ${f.name}, ${stamp}, ${f.url}, ${tx.json(f.payload)})`;
      }
      await tx`
        insert into raw.instagram_runs (snapshot_date, extracted_at, username, posts, media_count, followers, api_calls, triggered_by)
        values (${snapshotDate}, ${stamp}, ${NDN_USERNAME}, ${posts}, ${expected || null},
                ${profile.followers_count ?? null}, ${files.length}, ${triggeredBy})`;
    });

    const summary = { status: "done", snapshot_date: snapshotDate, posts, media_count: expected,
                      followers: profile.followers_count, api_calls: files.length };
    console.log(summary);
    return Response.json(summary);
  } catch (err) {
    const msg = err instanceof Error ? redact(err.message, token) : String(err);
    console.error("FAILED:", msg);
    return Response.json({ status: "failed", error: msg }, { status: 500 });
  }
});
