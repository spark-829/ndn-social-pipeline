// Supabase Edge Function: benchmark accounts (data set 6, sql/020_benchmarks.sql).
// Small on purpose (Vic 2026-10-21): daily account totals + weekly counts of the latest 50 uploads.
//   ?step=daily    YouTube channel totals (1 unit for all) + Instagram profile totals   (pg_cron daily)
//   ?step=weekly   latest 50 uploads per account: YouTube (2 units each) + Instagram    (pg_cron Monday)
//   ?step=catalog&account=K&platform=YouTube|Instagram[&after=cursor]   one-time full upload history (sql/021)
//   ?step=artist_ig[&limit=60]   artists' own Instagram followers (sql/024)          (pg_cron Wed, 4 calls an hour apart)
//   GET  ?step=tiktok                 -> {items: [{account_key, handle}]}  for extract_benchmarks_tiktok.py
//   POST ?step=tiktok_daily  {rows: [{account_key, followers, hearts, videos}]}
//   POST ?step=tiktok_weekly {rows: [{account_key, videos: [{id, title, url, published_at, views, likes, comments}]}]}
// One run-log row per call in raw.music_runs (part benchmarks_<step>).
// Secrets: YOUTUBE_API_KEY, IG_ACCESS_TOKEN, IG_USER_ID (same as youtube-snapshot / instagram-snapshot).
//          Caller must send header x-cron-secret matching vault secret 'ndn_cron_secret'.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const YT = "https://www.googleapis.com/youtube/v3";
const IG = "https://graph.facebook.com/v23.0";
const LATEST = 50;
const IG_MEDIA = "id,caption,media_product_type,timestamp,permalink,like_count,comments_count,view_count";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const phDate = () => new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);
const num = (v: unknown) => (v === undefined || v === null || v === "" ? null : Number(v));
// Cut by characters, not UTF-16 units: slicing through an emoji leaves half of it, which Postgres rejects.
const short = (s: unknown) =>
  (typeof s === "string" ? Array.from(s.toWellFormed().split("\n")[0]).slice(0, 150).join("") : null);

type Account = { account_key: string; tiktok_handle: string | null; youtube_channel_id: string | null; instagram_username: string | null };
type Video = { id: string; title: string | null; url: string | null; kind: string | null; published_at: string | null;
               views: number | null; likes: number | null; comments: number | null };

async function get(url: string, secret: string) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const resp = await fetch(url);
    const text = await resp.text();
    if (resp.ok) return JSON.parse(text);
    if ((resp.status === 429 || resp.status >= 500) && attempt < 3) { await new Promise((r) => setTimeout(r, 2000 * attempt)); continue; }
    throw new Error(`HTTP ${resp.status}: ${text.slice(0, 200).split(secret).join("REDACTED")}`);
  }
}

const ytKey = () => (Deno.env.get("YOUTUBE_API_KEY") ?? "").trim();
const yt = (endpoint: string, params: Record<string, string>) =>
  get(`${YT}/${endpoint}?` + new URLSearchParams({ ...params, key: ytKey() }), ytKey());

function ig(username: string, fields: string) {
  const token = (Deno.env.get("IG_ACCESS_TOKEN") ?? "").trim();
  const me = (Deno.env.get("IG_USER_ID") ?? "").trim();
  const f = `business_discovery.username(${username}){${fields}}`;
  return get(`${IG}/${me}?` + new URLSearchParams({ fields: f, access_token: token }), token)
    .then((d: any) => d.business_discovery);
}

async function saveDaily(day: string, key: string, platform: string, r: { followers?: unknown; views?: unknown; likes?: unknown; posts?: unknown }) {
  await sql`insert into raw.benchmark_daily (snapshot_date, account_key, platform, followers, total_views, total_likes, posts)
    values (${day}, ${key}, ${platform}, ${num(r.followers)}, ${num(r.views)}, ${num(r.likes)}, ${num(r.posts)})
    on conflict (snapshot_date, account_key, platform) do update set followers = excluded.followers,
      total_views = excluded.total_views, total_likes = excluded.total_likes, posts = excluded.posts, fetched_at = now()`;
}

async function saveVideos(day: string, key: string, platform: string, videos: Video[]) {
  if (!videos.length) return;
  await sql.begin(async (tx) => {
    await tx`insert into raw.benchmark_video (platform, video_id, account_key, published_at, title, url, kind, first_seen)
      select ${platform}, v.id, ${key}, v.published_at, left(v.title, 150), v.url, v.kind, ${day}::date
      from jsonb_to_recordset(${tx.json(videos as any)}::jsonb)
           as v(id text, title text, url text, kind text, published_at timestamptz)
      on conflict (platform, video_id) do nothing`;
    await tx`insert into raw.benchmark_video_weekly (snapshot_date, platform, video_id, views, likes, comments)
      select ${day}::date, ${platform}, v.id, v.views, v.likes, v.comments
      from jsonb_to_recordset(${tx.json(videos as any)}::jsonb) as v(id text, views bigint, likes bigint, comments bigint)
      on conflict (snapshot_date, platform, video_id) do update set views = excluded.views,
        likes = excluded.likes, comments = excluded.comments`;
  });
}

async function daily(accts: Account[], day: string, log: Record<string, unknown>) {
  const ids = accts.map((a) => a.youtube_channel_id).filter(Boolean) as string[];
  if (ids.length) {
    const res = await yt("channels", { part: "statistics", id: ids.join(",") });
    for (const it of res.items ?? []) {
      const a = accts.find((x) => x.youtube_channel_id === it.id)!;
      await saveDaily(day, a.account_key, "YouTube", { followers: it.statistics.subscriberCount,
        views: it.statistics.viewCount, posts: it.statistics.videoCount });
      log[`${a.account_key}.YouTube`] = "ok";
    }
  }
  for (const a of accts.filter((x) => x.instagram_username)) {
    try {
      const bd = await ig(a.instagram_username!, "followers_count,media_count");
      await saveDaily(day, a.account_key, "Instagram", { followers: bd.followers_count, posts: bd.media_count });
      log[`${a.account_key}.Instagram`] = "ok";
    } catch (e) { log[`${a.account_key}.Instagram`] = String(e).slice(0, 200); }
  }
}

async function weekly(accts: Account[], day: string, log: Record<string, unknown>) {
  for (const a of accts.filter((x) => x.youtube_channel_id)) {
    try {
      const pl = await yt("playlistItems", { part: "contentDetails", playlistId: "UU" + a.youtube_channel_id!.slice(2), maxResults: String(LATEST) });
      const ids = (pl.items ?? []).map((i: any) => i.contentDetails.videoId);
      const vs = ids.length ? await yt("videos", { part: "snippet,statistics", id: ids.join(",") }) : { items: [] };
      const videos: Video[] = (vs.items ?? []).map((v: any) => ({ id: v.id, title: short(v.snippet.title),
        url: `https://www.youtube.com/watch?v=${v.id}`, kind: "video", published_at: v.snippet.publishedAt,
        views: num(v.statistics.viewCount), likes: num(v.statistics.likeCount), comments: num(v.statistics.commentCount) }));
      await saveVideos(day, a.account_key, "YouTube", videos);
      log[`${a.account_key}.YouTube`] = videos.length;
    } catch (e) { log[`${a.account_key}.YouTube`] = String(e).slice(0, 200); }
  }
  for (const a of accts.filter((x) => x.instagram_username)) {
    try {
      const bd = await ig(a.instagram_username!, `media.limit(${LATEST}){${IG_MEDIA}}`);
      const videos: Video[] = (bd.media?.data ?? []).map((m: any) => ({ id: m.id, title: short(m.caption), url: m.permalink,
        kind: m.media_product_type, published_at: m.timestamp, views: num(m.view_count), likes: num(m.like_count),
        comments: num(m.comments_count) }));
      await saveVideos(day, a.account_key, "Instagram", videos);
      log[`${a.account_key}.Instagram`] = videos.length;
    } catch (e) { log[`${a.account_key}.Instagram`] = String(e).slice(0, 200); }
  }
}

// One-time catalog (sql/021): every upload of one account on one platform, date + today's counts.
// YouTube: whole uploads playlist (~2 units per 50 videos). Instagram: back to IG_SINCE (Business
// Discovery pages of 100). Call per account and platform so each call stays well under the time limit.
// Instagram saves page by page and stops after IG_PAGES pages or at Meta's hourly app limit; the log
// then holds next_after, and ?after=<cursor> resumes (Wish 107.5 has ~29k posts, 2026-10-21).
const IG_SINCE = "2024-01-01";
const IG_PAGES = 25;
async function catalog(a: Account, platform: string, day: string, log: Record<string, unknown>, start?: string) {
  const videos: Video[] = [];
  if (platform === "YouTube" && a.youtube_channel_id) {
    let token: string | undefined;
    do {
      const params: Record<string, string> = { part: "contentDetails", playlistId: "UU" + a.youtube_channel_id.slice(2), maxResults: "50" };
      if (token) params.pageToken = token;
      const pl = await yt("playlistItems", params);
      const ids = (pl.items ?? []).map((i: any) => i.contentDetails.videoId);
      if (ids.length) {
        const vs = await yt("videos", { part: "snippet,statistics", id: ids.join(",") });
        for (const v of vs.items ?? []) videos.push({ id: v.id, title: short(v.snippet.title),
          url: `https://www.youtube.com/watch?v=${v.id}`, kind: "video", published_at: v.snippet.publishedAt,
          views: num(v.statistics.viewCount), likes: num(v.statistics.likeCount), comments: num(v.statistics.commentCount) });
      }
      token = pl.nextPageToken;
    } while (token);
  } else if (platform === "Instagram" && a.instagram_username) {
    let after = start, pages = 0, saved = 0, done = false;
    try {
      do {
        const bd = await ig(a.instagram_username, `media${after ? `.after(${after})` : ""}.limit(100){${IG_MEDIA}}`);
        const page: Video[] = [];
        for (const m of bd.media?.data ?? []) {
          if (m.timestamp < IG_SINCE) { done = true; break; }
          page.push({ id: m.id, title: short(m.caption), url: m.permalink, kind: m.media_product_type,
            published_at: m.timestamp, views: num(m.view_count), likes: num(m.like_count), comments: num(m.comments_count) });
        }
        await saveVideos(day, a.account_key, platform, page);
        saved += page.length;
        // Business Discovery gives only cursors (no paging.next), and pages can be short mid-list:
        // go on while a cursor comes back and the page wasn't empty
        after = (bd.media?.data ?? []).length ? bd.media?.paging?.cursors?.after : undefined;
        pages++;
      } while (after && !done && pages < IG_PAGES);
    } catch (e) {
      log[`${a.account_key}.${platform}.error`] = String(e).slice(0, 200);
    }
    log[`${a.account_key}.${platform}`] = saved;
    if (after && !done) log.next_after = after;
    return;
  } else {
    throw new Error(`no ${platform} account for ${a.account_key}`);
  }
  for (let i = 0; i < videos.length; i += 1000) await saveVideos(day, a.account_key, platform, videos.slice(i, i + 1000));
  log[`${a.account_key}.${platform}`] = videos.length;
}

// Artists' own Instagram (sql/024): followers + posts for up to `limit` artists not fetched in 6 days.
// Business Discovery only sees Business/Creator accounts; others are saved as found = false.
async function artistIg(day: string, limit: number, log: Record<string, unknown>) {
  const due = await sql<{ spotify_id: string; username: string }[]>`
    select a.spotify_id, a.username from staging.artist_instagram a
    where not exists (select 1 from raw.artist_instagram_weekly w
                      where w.spotify_id = a.spotify_id and w.snapshot_date > ${day}::date - 6)
    order by a.spotify_id limit ${limit}`;
  let found = 0, missing = 0;
  for (const a of due) {
    try {
      const bd = await ig(a.username, "followers_count,media_count");
      await sql`insert into raw.artist_instagram_weekly (snapshot_date, spotify_id, username, found, followers, posts)
        values (${day}, ${a.spotify_id}, ${a.username}, true, ${num(bd.followers_count)}, ${num(bd.media_count)})
        on conflict (snapshot_date, spotify_id) do nothing`;
      found++;
    } catch (e) {
      const msg = String(e).slice(0, 200);
      if (/request limit|\(#4\)|\(#17\)|\(#32\)/i.test(msg)) { log.stopped = msg; break; }   // Meta's hourly limit: next call
      await sql`insert into raw.artist_instagram_weekly (snapshot_date, spotify_id, username, found, error)
        values (${day}, ${a.spotify_id}, ${a.username}, false, ${msg}) on conflict (snapshot_date, spotify_id) do nothing`;
      missing++;
    }
  }
  log.artist_ig = { due: due.length, found, missing };
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const url = new URL(req.url);
  const step = url.searchParams.get("step") ?? "";
  const by = url.searchParams.get("by") ?? "manual";
  const day = phDate();
  const accts = await sql<Account[]>`
    select account_key, tiktok_handle, youtube_channel_id, instagram_username
    from raw.benchmark_accounts where active order by account_key`;

  if (step === "tiktok" && req.method === "GET") {
    return Response.json({ items: accts.filter((a) => a.tiktok_handle).map((a) => ({ account_key: a.account_key, handle: a.tiktok_handle })) });
  }

  const log: Record<string, unknown> = {};
  try {
    if (step === "daily") await daily(accts, day, log);
    else if (step === "weekly") await weekly(accts, day, log);
    else if (step === "catalog") {
      const a = accts.find((x) => x.account_key === url.searchParams.get("account"));
      if (!a) return new Response("unknown or inactive account", { status: 400 });
      await catalog(a, url.searchParams.get("platform") ?? "", day, log, url.searchParams.get("after") ?? undefined);
    }
    else if (step === "artist_ig") await artistIg(day, Number(url.searchParams.get("limit") ?? 60), log);
    else if (step === "tiktok_daily") {
      for (const r of (await req.json()).rows ?? []) {
        await saveDaily(day, r.account_key, "TikTok", { followers: r.followers, likes: r.hearts, posts: r.videos });
        log[`${r.account_key}.TikTok`] = "ok";
      }
    } else if (step === "tiktok_weekly") {
      for (const r of (await req.json()).rows ?? []) {
        const videos: Video[] = (r.videos ?? []).map((v: any) => ({ ...v, kind: "video", title: short(v.title) }));
        await saveVideos(day, r.account_key, "TikTok", videos);
        log[`${r.account_key}.TikTok`] = videos.length;
      }
    } else {
      return new Response(`unknown step '${step}'`, { status: 400 });
    }
    const failed = Object.values(log).some((v) => typeof v === "string" && v !== "ok");
    const status = failed ? "partial" : "ok";
    await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
      values (${"benchmarks_" + step}, ${by}, now(), ${status}, ${sql.json({ day, ...log } as any)})`;
    return Response.json({ status, day, ...log });
  } catch (err) {
    const msg = String(err).slice(0, 300);
    await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
      values (${"benchmarks_" + step}, ${by}, now(), 'failed', ${sql.json({ day, error: msg, ...log } as any)})`;
    return Response.json({ status: "failed", error: msg }, { status: 500 });
  }
});
