// Supabase Edge Function: data set "trends + artist catalogs" (sql/013_music_trends.sql).
// Extract + Load only: every reply is stored untouched in raw.*; the staging views do the cleaning.
//
//   POST ?part=trends   PH trends, one snapshot per PH date (re-running the same day overwrites it):
//                       - TikTok Creative Center top hashtags, last 7 days, overall + 19 industries.
//                         Plain request, no signing (checked 2026-10-19); logged out = top 3 per list.
//                       - kworb.net Spotify Philippines weekly chart (HTML page).
//   POST ?part=deezer   Deezer catalog for every artist on NDN's YouTube, in 3 steps, each only for
//                       what is missing or stale: search names -> song check (name + a posted
//                       song) -> releases per artist (refetched
//                       after 6 days, to catch new releases) -> track list per release (once).
//                       Stops after `budget` requests (default 300) so a call stays well inside the
//                       Edge Function time limit; pg_cron calls it again until nothing is left.
//   ?by=pg_cron|manual  who called (stored in raw.music_runs)
// Caller must send header x-cron-secret matching vault secret 'ndn_cron_secret'.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const TIKTOK_API = "https://ads.tiktok.com/CreativeOne/KnowledgeAPI/GetHashtagList";
// 26 and 30 returned nothing when probed; 10-29 are the industries the page filters by.
const INDUSTRIES = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 27, 28, 29];
const KWORB = "https://kworb.net/spotify/country/ph_weekly.html";
const DEEZER = "https://api.deezer.com";
const DEEZER_PER_SECOND = 8;           // Deezer allows 50 requests per 5 s
const TIME_LIMIT_MS = 110_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const phDate = () => new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);

async function trends(): Promise<Record<string, unknown>> {
  const day = phDate();
  const lists: [string, Record<string, unknown>][] = [["hashtag_7d_all", {}]];
  for (const id of INDUSTRIES) lists.push([`hashtag_7d_${id}`, { industryID: id * 1_000_000_000 }]);

  let hashtags = 0;
  const failed: string[] = [];
  for (const [chart, extra] of lists) {
    const body = { timeRange: 7, countryCode: "PH", page: 1, limit: 20, ...extra };
    const resp = await fetch(TIKTOK_API, {
      method: "POST",
      headers: { "Content-Type": "application/json", "User-Agent": UA },
      body: JSON.stringify(body),
    });
    const text = await resp.text();
    let json: any;
    try { json = JSON.parse(text); } catch { json = null; }
    if (resp.status !== 200 || json?.BaseResp?.StatusCode !== 0 || !Array.isArray(json?.items)) {
      failed.push(`${chart}: HTTP ${resp.status} ${text.slice(0, 120)}`);
      continue;
    }
    hashtags += json.items.length;
    await sql`
      insert into raw.trend_responses (source, chart, snapshot_date, url, request, payload)
      values ('tiktok_cc', ${chart}, ${day}, ${TIKTOK_API}, ${sql.json(body)}, ${sql.json(json)})
      on conflict (source, chart, snapshot_date) do update
        set fetched_at = now(), request = excluded.request, payload = excluded.payload`;
    await sleep(500);
  }

  const page = await fetch(KWORB, { headers: { "User-Agent": UA } });
  const html = await page.text();
  const kworbRows = (html.match(/<tr/g) ?? []).length - 1;
  if (page.status === 200 && html.includes("Spotify Weekly Chart - Philippines") && kworbRows > 50) {
    await sql`
      insert into raw.trend_responses (source, chart, snapshot_date, url, body)
      values ('kworb', 'spotify_ph_weekly', ${day}, ${KWORB}, ${html})
      on conflict (source, chart, snapshot_date) do update set fetched_at = now(), body = excluded.body`;
  } else {
    failed.push(`kworb: HTTP ${page.status}, ${kworbRows} rows`);
  }
  return { snapshot_date: day, tiktok_lists: lists.length - failed.filter((f) => f.startsWith("hashtag")).length,
           hashtags, kworb_rows: kworbRows, failed };
}

// One Deezer GET. Deezer reports its rate limit inside a 200 reply ({"error":{"code":4}}).
async function deezer(path: string): Promise<{ json: any } | null> {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const resp = await fetch(DEEZER + path);
    const text = await resp.text();
    let json: any = null;
    try { json = JSON.parse(text); } catch { /* not JSON */ }
    if (resp.status === 200 && json && !json.error) return { json };
    if (json?.error?.code === 800) return null;                  // "no data": artist/album gone
    await sleep(attempt * 2500);
  }
  throw new Error(`Deezer kept failing for ${path}`);
}

async function deezerPart(budget: number) {
  const started = Date.now();
  let used = 0;
  const done = { searched: 0, songChecks: 0, artists: 0, albums: 0 };
  const outOfTime = () => used >= budget || Date.now() - started > TIME_LIMIT_MS;

  // Runs jobs a few at a time, about DEEZER_PER_SECOND requests per second.
  async function run<T>(items: T[], job: (item: T) => Promise<number>) {
    for (let i = 0; i < items.length && !outOfTime(); i += DEEZER_PER_SECOND) {
      const t0 = Date.now();
      const batch = items.slice(i, i + Math.min(DEEZER_PER_SECOND, budget - used));
      const counts = await Promise.all(batch.map(job));
      used += counts.reduce((a, b) => a + b, 0);
      await sleep(Math.max(0, 1000 - (Date.now() - t0)));
    }
  }

  // 1. Search every NDN name not searched yet (names with no match are retried after 30 days).
  const names = await sql`
    select distinct on (c.name_key) c.name_key, c.name
    from staging.ndn_artist_credit c
    left join raw.deezer_search s on s.query_key = c.name_key
    left join staging.deezer_artist_match m on m.query_key = c.name_key
    where s.query_key is null or (m.match_type = 'none' and s.fetched_at < now() - interval '30 days')
    order by c.name_key, c.part_no`;
  await run(names, async (n: any) => {
    const r = await deezer(`/search/artist?limit=10&q=${encodeURIComponent(n.name)}`);
    await sql`
      insert into raw.deezer_search (query_key, query, payload) values (${n.name_key}, ${n.name}, ${sql.json(r?.json ?? { data: [] })})
      on conflict (query_key) do update set query = excluded.query, fetched_at = now(), payload = excluded.payload`;
    done.searched++;
    return 1;
  });

  // 1b. Song check: search "<name> <song>" with a song NDN posted; staging.deezer_artist_match
  //     trusts the artist id that comes back with that song (fixes same-name artists).
  const probes = outOfTime() ? [] : await sql`
    select p.name_key, p.name, p.song from staging.ndn_artist_probe p
    left join raw.deezer_track_search t using (name_key)
    where t.name_key is null`;
  await run(probes, async (p: any) => {
    const query = `${p.name} ${p.song}`;
    const r = await deezer(`/search?limit=10&q=${encodeURIComponent(query)}`);
    await sql`
      insert into raw.deezer_track_search (name_key, query, payload) values (${p.name_key}, ${query}, ${sql.json(r?.json ?? { data: [] })})
      on conflict (name_key) do update set query = excluded.query, fetched_at = now(), payload = excluded.payload`;
    done.songChecks++;
    return 1;
  });

  // 2. Releases of every matched artist (new ones, or last fetched more than 6 days ago).
  const artists = outOfTime() ? [] : await sql`
    select distinct a.deezer_artist_id
    from staging.ndn_artist a
    left join raw.deezer_artist_albums x using (deezer_artist_id)
    where a.deezer_artist_id is not null and (x.deezer_artist_id is null or x.fetched_at < now() - interval '6 days')`;
  await run(artists, async (a: any) => {
    const data: unknown[] = [];
    let path: string | null = `/artist/${a.deezer_artist_id}/albums?limit=100`;
    let calls = 0;
    while (path && calls < 5) {
      const r = await deezer(path);
      calls++;
      if (!r) break;
      data.push(...(r.json.data ?? []));
      path = r.json.next ? String(r.json.next).replace(DEEZER, "") : null;
    }
    await sql`
      insert into raw.deezer_artist_albums (deezer_artist_id, payload) values (${a.deezer_artist_id}, ${sql.json({ data })})
      on conflict (deezer_artist_id) do update set fetched_at = now(), payload = excluded.payload`;
    done.artists++;
    return calls;
  });

  // 3. Track list of every release we don't have yet (only artists matched right now).
  const albums = outOfTime() ? [] : await sql`
    select distinct r.album_id from staging.music_release r
    join (select distinct deezer_artist_id from staging.ndn_artist where deezer_artist_id is not null) a using (deezer_artist_id)
    left join raw.deezer_album_tracks t using (album_id)
    where t.album_id is null`;
  await run(albums, async (al: any) => {
    const r = await deezer(`/album/${al.album_id}/tracks?limit=200`);
    await sql`
      insert into raw.deezer_album_tracks (album_id, payload) values (${al.album_id}, ${sql.json(r?.json ?? { data: [] })})
      on conflict (album_id) do update set fetched_at = now(), payload = excluded.payload`;
    done.albums++;
    return 1;
  });

  const [left] = await sql`
    select
      (select count(distinct c.name_key) from staging.ndn_artist_credit c
        left join raw.deezer_search s on s.query_key = c.name_key where s.query_key is null) as names_left,
      (select count(distinct a.deezer_artist_id) from staging.ndn_artist a
        left join raw.deezer_artist_albums x using (deezer_artist_id)
        where a.deezer_artist_id is not null and x.deezer_artist_id is null) as artists_left,
      (select count(distinct r.album_id) from staging.music_release r
        join (select distinct deezer_artist_id from staging.ndn_artist where deezer_artist_id is not null) a using (deezer_artist_id)
        left join raw.deezer_album_tracks t using (album_id) where t.album_id is null) as albums_left`;
  const finished = Number(left.names_left) + Number(left.artists_left) + Number(left.albums_left) === 0;
  return { requests: used, ...done, ...left, finished };
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const url = new URL(req.url);
  const part = url.searchParams.get("part");
  if (part !== "trends" && part !== "deezer") return new Response("expected ?part=trends or ?part=deezer", { status: 400 });
  const by = url.searchParams.get("by") ?? "manual";
  const budget = Math.min(Number(url.searchParams.get("budget") ?? 300) || 300, 800);

  const [{ run_id }] = await sql`insert into raw.music_runs (part, run_by) values (${part}, ${by}) returning run_id`;
  try {
    const detail = part === "trends" ? await trends() : await deezerPart(budget);
    const status = part === "trends" && (detail as any).failed.length ? "partial" : "ok";
    await sql`update raw.music_runs set finished_at = now(), status = ${status}, detail = ${sql.json(detail)} where run_id = ${run_id}`;
    return Response.json({ run_id, status, ...detail });
  } catch (e) {
    const message = String((e as Error)?.message ?? e).slice(0, 500);
    await sql`update raw.music_runs set finished_at = now(), status = 'failed', detail = ${sql.json({ error: message })} where run_id = ${run_id}`;
    return Response.json({ run_id, status: "failed", error: message }, { status: 500 });
  }
});
