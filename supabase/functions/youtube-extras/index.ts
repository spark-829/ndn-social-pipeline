// Supabase Edge Function: YouTube extras for the YouTube question list (sql/016_youtube_extras.sql).
//   POST ?part=weekly    Shorts list, NDN playlists + items, ~90 searches "<song> <artist>"  (pg_cron Mon 11:00 PH)
//   POST ?part=chart     PH Trending Music list (mostPopular, category 10)                     (pg_cron daily 09:10 PH)
//   POST ?part=premiere  concurrent viewers of a Premiere live right now                      (pg_cron 19:02 + 19:05 PH)
//   GET  ?part=heatmap_todo&limit=N   long videos whose "Most replayed" graph is due      (extract_youtube_heatmap.py)
//   POST ?part=heatmap_save {rows}    saves graphs; POST ?part=run {status, detail} logs the script's run
// weekly and chart run once per PH day (add &force=1 to run again). Replies are trimmed to the
// fields listed in sql/016 to save space.
// Secrets: YOUTUBE_API_KEY (Edge Function secret); caller sends x-cron-secret (vault 'ndn_cron_secret').
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const API = "https://www.googleapis.com/youtube/v3";
const NDN = "UCNO66UYt0xSeEMw9d5v-37w";
const UPLOADS = "UU" + NDN.slice(2), SHORTS = "UUSH" + NDN.slice(2);   // UUSH: undocumented, tested 2026-10-20
const SEARCH_NEWEST = 30, SEARCH_TOP = 60;                                // search bucket: 100 calls a day

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const phDate = () => new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);
const key = () => (Deno.env.get("YOUTUBE_API_KEY") ?? "").trim();
const redact = (s: string) => (key() ? s.split(key()).join("REDACTED") : s);
let units = 0, searches = 0;

async function api(endpoint: string, params: Record<string, string>) {
  const url = `${API}/${endpoint}?` + new URLSearchParams({ ...params, key: key() });
  for (let attempt = 1; attempt <= 3; attempt++) {
    const resp = await fetch(url);
    const text = await resp.text();
    if (resp.status === 200) {
      endpoint === "search" ? searches++ : units++;
      return JSON.parse(text);
    }
    if (resp.status === 403 && text.includes("quotaExceeded")) throw new Error(`${endpoint}: quota used up (resets 3-4 pm PH)`);
    if ((resp.status === 429 || resp.status >= 500) && attempt < 3) { await new Promise((r) => setTimeout(r, 2000 * attempt)); continue; }
    throw new Error(`${endpoint}: HTTP ${resp.status}: ${redact(text.slice(0, 200))}`);
  }
}

async function allItems(endpoint: string, params: Record<string, string>) {
  const items: any[] = [];
  let token: string | undefined;
  do {
    const j = await api(endpoint, { ...params, maxResults: "50", ...(token ? { pageToken: token } : {}) });
    items.push(...(j.items ?? []));
    token = j.nextPageToken;
  } while (token);
  return items;
}

async function store(day: string, part: string, itemKey: string, payload: unknown, meta: unknown = null) {
  await sql`insert into raw.youtube_extras (snapshot_date, part, item_key, meta, payload)
    values (${day}, ${part}, ${itemKey}, ${meta ? sql.json(meta as any) : null}, ${sql.json(payload as any)})
    on conflict (snapshot_date, part, item_key) do update set extracted_at = now(), meta = excluded.meta, payload = excluded.payload`;
}

async function weekly(day: string) {
  // 1. Shorts: YouTube's own list
  const shorts = await allItems("playlistItems", { part: "contentDetails", playlistId: SHORTS });
  await store(day, "shorts", "UUSH", { ids: shorts.map((i) => i.contentDetails.videoId) });

  // 2. Playlists and their items (with the date each video was added)
  const pls = await allItems("playlists", { part: "snippet,contentDetails", channelId: NDN });
  await store(day, "playlists", "all", { items: pls.map((p) => ({ id: p.id, title: p.snippet.title,
    itemCount: p.contentDetails.itemCount, publishedAt: p.snippet.publishedAt })) });
  for (const p of pls) {
    const items = await allItems("playlistItems", { part: "snippet,contentDetails", playlistId: p.id });
    await store(day, "playlist_items", p.id, { items: items.map((i) => ({ videoId: i.contentDetails.videoId,
      position: i.snippet.position, addedAt: i.snippet.publishedAt })) });
  }

  // 3. Search rank: the newest sessions + the sessions earning the most views this week
  const targets = await sql`
    with f as (
      select v.video_id, v.published_at,
             coalesce(v.song, v.title) || coalesce(' ' || nullif(btrim(regexp_replace(v.artist, '^[-—–\\s]+', '')), ''), '') as q
      from mart.dim_video v join staging.youtube_video_format f using (video_id)
      where v.platform = 'YouTube' and not f.is_short
    ), g as (
      select video_id, max(views) filter (where snapshot_date = (select max(snapshot_date) from raw.youtube_runs))
                     - max(views) filter (where snapshot_date = (select max(snapshot_date) - 7 from raw.youtube_runs)) as gain
      from staging.youtube_video_snapshot
      where snapshot_date >= (select max(snapshot_date) - 7 from raw.youtube_runs)
      group by 1
    ), newest as (select video_id, q, 'newest' as reason from f order by published_at desc limit ${SEARCH_NEWEST})
    select * from newest
    union all
    (select f.video_id, f.q, 'top_week' from f join g using (video_id)
     where f.video_id not in (select video_id from newest) order by g.gain desc nulls last limit ${SEARCH_TOP})`;
  const done = new Set((await sql`select item_key from raw.youtube_extras where part = 'search' and snapshot_date = ${day}`)
    .map((r: any) => r.item_key));
  let failed = 0;
  for (let i = 0; i < targets.length; i += 5) {
    await Promise.all(targets.slice(i, i + 5).filter((t: any) => !done.has(t.video_id)).map(async (t: any) => {
      try {
        const j = await api("search", { part: "snippet", q: t.q, type: "video", regionCode: "PH", maxResults: "25" });
        await store(day, "search", t.video_id, { items: (j.items ?? []).map((it: any) => ({ id: it.id.videoId,
          channelId: it.snippet.channelId, channelTitle: it.snippet.channelTitle, title: it.snippet.title,
          publishedAt: it.snippet.publishedAt })) }, { q: t.q, reason: t.reason });
      } catch (e) {
        failed++;
        if (String(e).includes("quota")) throw e;
      }
    }));
  }
  return { shorts: shorts.length, playlists: pls.length, searches: targets.length - done.size, search_failed: failed };
}

async function chart(day: string) {
  const j = await api("videos", { part: "snippet,statistics", chart: "mostPopular", regionCode: "PH",
                                   videoCategoryId: "10", maxResults: "50" });
  const items = (j.items ?? []).map((v: any) => ({ id: v.id, channelId: v.snippet.channelId,
    channelTitle: v.snippet.channelTitle, title: v.snippet.title, categoryId: v.snippet.categoryId,
    publishedAt: v.snippet.publishedAt, views: v.statistics?.viewCount, likes: v.statistics?.likeCount }));
  await store(day, "chart", "PH_10", { items });
  return { videos: items.length, ndn: items.filter((i: any) => i.channelId === NDN).length };
}

async function premiere(day: string) {
  const newest = await api("playlistItems", { part: "contentDetails", playlistId: UPLOADS, maxResults: "5" });
  const ids = (newest.items ?? []).map((i: any) => i.contentDetails.videoId).join(",");
  if (!ids) return { live: 0 };
  const j = await api("videos", { part: "snippet,statistics,liveStreamingDetails", id: ids });
  const live = (j.items ?? []).filter((v: any) => v.snippet.liveBroadcastContent === "live");
  const hhmi = new Date().toISOString().slice(11, 16);
  for (const v of live) {
    await store(day, "premiere", `${v.id}|${hhmi}`, { id: v.id, title: v.snippet.title,
      concurrentViewers: v.liveStreamingDetails?.concurrentViewers ?? null, views: v.statistics?.viewCount ?? null,
      scheduledStartTime: v.liveStreamingDetails?.scheduledStartTime ?? null,
      actualStartTime: v.liveStreamingDetails?.actualStartTime ?? null });
  }
  return { live: live.length, viewers: live.map((v: any) => v.liveStreamingDetails?.concurrentViewers) };
}

// Long videos whose graph is due: never fetched; no graph yet and last try over 6 days ago;
// or under 60 days old (the graph still changes) and last fetch over 6 days ago.
async function heatmapTodo(limit: number) {
  return await sql`
    select f.video_id, f.duration_sec from staging.youtube_video_format f
    left join lateral (select snapshot_date, found from raw.youtube_heatmap h where h.video_id = f.video_id
                       order by snapshot_date desc limit 1) h on true
    where not f.is_short
      and (h.snapshot_date is null
           or (h.snapshot_date < ${phDate()}::date - 6 and (not h.found or f.published_at > now() - interval '60 days')))
    order by f.published_at desc limit ${limit}`;
}

async function heatmapSave(rows: any[]) {
  const day = phDate();
  for (const r of rows) {
    await sql`insert into raw.youtube_heatmap (video_id, snapshot_date, found, duration_sec, points)
      values (${r.video_id}, ${day}, ${!!r.found}, ${r.duration_sec ?? null}, ${r.points ? sql.json(r.points) : null})
      on conflict (video_id, snapshot_date) do update set fetched_at = now(), found = excluded.found,
        duration_sec = excluded.duration_sec, points = excluded.points`;
  }
  return { saved: rows.length };
}

async function logRun(part: string, by: string, status: string, detail: unknown) {
  await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
    values (${part}, ${by}, now(), ${status}, ${sql.json(detail as any)})`;
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const url = new URL(req.url);
  const part = url.searchParams.get("part") ?? "";
  const by = url.searchParams.get("by") ?? "manual";
  const force = url.searchParams.get("force") === "1";
  const day = phDate();
  units = 0; searches = 0;
  try {
    if (part === "heatmap_todo") {
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 1000) || 1000, 2000);
      return Response.json({ part, items: await heatmapTodo(limit) });
    }
    if (part === "heatmap_save") {
      const body = await req.json();
      return Response.json(await heatmapSave(Array.isArray(body?.rows) ? body.rows : []));
    }
    if (part === "run") {
      const body = await req.json();
      await logRun("youtube_heatmap", by, body.status ?? "ok", body.detail ?? {});
      return Response.json({ status: "logged" });
    }
    if (!key()) return new Response("YOUTUBE_API_KEY secret missing", { status: 500 });
    if (part === "weekly" || part === "chart") {
      const marker = part === "weekly" ? "playlists" : "chart";
      const already = await sql`select 1 from raw.youtube_extras where snapshot_date = ${day} and part = ${marker}`;
      if (already.length && !force) return Response.json({ status: "already_done", part, day });
      const detail = { ...(part === "weekly" ? await weekly(day) : await chart(day)), units, searches };
      await logRun(`youtube_${part}`, by, "ok", detail);
      return Response.json({ status: "done", part, ...detail });
    }
    if (part === "premiere") {
      const detail = await premiere(day);
      if (detail.live) await logRun("youtube_premiere", by, "ok", { ...detail, units });
      return Response.json({ status: "done", part, ...detail, units });
    }
    return Response.json({ error: `unknown part ${part}` }, { status: 400 });
  } catch (e) {
    const msg = redact(String((e as Error)?.message ?? e)).slice(0, 500);
    if (["weekly", "chart", "premiere"].includes(part)) {
      await logRun(`youtube_${part}`, by, "failed", { error: msg, units, searches }).catch(() => {});
    }
    return Response.json({ status: "failed", error: msg }, { status: 500 });
  }
});
