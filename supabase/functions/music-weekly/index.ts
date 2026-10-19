// Supabase Edge Function: data set "trends + artist catalogs" (sql/013_music_trends.sql).
// Extract + Load only: every reply is stored untouched in raw.*; the staging views do the cleaning.
//
//   POST ?part=trends   PH trends, one snapshot per PH date (re-running the same day overwrites it):
//                       - TikTok Creative Center top hashtags, last 7 days, overall + 19 industries.
//                         Plain request, no signing (checked 2026-10-19); logged out = top 3 per list.
//                       - kworb.net Spotify Philippines weekly chart (HTML page).
//   GET  ?part=deezer_todo[&since=ISO time]  next Deezer step for extract_music_catalog.py (home server, PH IP):
//                           {step, items: [{key, path, query?}]}; step "done" when nothing is left.
//   POST ?part=deezer_save  {step, rows: [{key, query?, payload}]} -> raw.deezer_* (untouched), or
//                           {step: "run", status, detail} -> raw.music_runs
//   ?by=pg_cron|server|manual  who called (stored in raw.music_runs)
// Caller must send header x-cron-secret matching vault secret 'ndn_cron_secret'.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
const TIKTOK_API = "https://ads.tiktok.com/CreativeOne/KnowledgeAPI/GetHashtagList";
// 26 and 30 returned nothing when probed; 10-29 are the industries the page filters by.
const INDUSTRIES = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 27, 28, 29];
const KWORB = "https://kworb.net/spotify/country/ph_weekly.html";

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

// Deezer runs from a Philippine IP (extract_music_catalog.py on the home server): Deezer filters
// its catalog by the caller's country, and from Supabase's servers (Seoul) Lola Amour has 3
// releases instead of 33 (checked 2026-10-20). This function only says what to fetch and saves it.
const TODO_LIMIT = 400;

// What the server should fetch next, one step at a time (each step depends on the one before):
// 1 names not searched (no-match names retried after 30 days) -> 2 song checks -> 3 release lists
// (new artists, or older than 6 days) -> 4 track lists of releases we don't have.
// since (optional ISO time): rows fetched before it count as missing, to refetch everything once.
async function deezerTodo(since: string | null) {
  const before = since ?? "1970-01-01T00:00:00Z";   // postgres.js can't send "-infinity" as a date
  const names = await sql`
    select distinct on (c.name_key) c.name_key as key, c.name as query
    from staging.ndn_artist_credit c
    left join raw.deezer_search s on s.query_key = c.name_key
    left join staging.deezer_artist_match m on m.query_key = c.name_key
    where s.query_key is null or s.fetched_at < ${before}::timestamptz
       or (m.match_type = 'none' and s.fetched_at < now() - interval '30 days')
    order by c.name_key, c.part_no limit ${TODO_LIMIT}`;
  if (names.length) return { step: "search", items: names.map((n) => ({ key: n.key, path: `/search/artist?limit=10&q=${encodeURIComponent(n.query)}`, query: n.query })) };

  const probes = await sql`
    select p.name_key as key, p.name || ' ' || p.song as query from staging.ndn_artist_probe p
    left join raw.deezer_track_search t using (name_key)
    where t.name_key is null or t.fetched_at < ${before}::timestamptz limit ${TODO_LIMIT}`;
  if (probes.length) return { step: "probe", items: probes.map((n) => ({ key: n.key, path: `/search?limit=10&q=${encodeURIComponent(n.query)}`, query: n.query })) };

  const artists = await sql`
    select distinct a.deezer_artist_id::text as key
    from staging.ndn_artist a
    left join raw.deezer_artist_albums x using (deezer_artist_id)
    where a.deezer_artist_id is not null and (x.deezer_artist_id is null or x.fetched_at < now() - interval '6 days'
                                              or x.fetched_at < ${before}::timestamptz)
    limit ${TODO_LIMIT}`;
  if (artists.length) return { step: "albums", items: artists.map((a) => ({ key: a.key, path: `/artist/${a.key}/albums?limit=100` })) };

  const albums = await sql`
    select distinct r.album_id::text as key from staging.music_release r
    join (select distinct deezer_artist_id from staging.ndn_artist where deezer_artist_id is not null) a using (deezer_artist_id)
    left join raw.deezer_album_tracks t using (album_id)
    where t.album_id is null or t.fetched_at < ${before}::timestamptz limit ${TODO_LIMIT}`;
  if (albums.length) return { step: "tracks", items: albums.map((a) => ({ key: a.key, path: `/album/${a.key}/tracks?limit=200` })) };

  return { step: "done", items: [] };
}

// Saves Deezer replies untouched. body: {step, rows: [{key, query?, payload}]} or {step: "run", detail}.
async function deezerSave(body: any, by: string) {
  const rows: any[] = Array.isArray(body?.rows) ? body.rows : [];
  for (const r of rows) {
    const payload = sql.json(r.payload ?? { data: [] });
    if (body.step === "search") {
      await sql`insert into raw.deezer_search (query_key, query, payload) values (${r.key}, ${r.query}, ${payload})
        on conflict (query_key) do update set query = excluded.query, fetched_at = now(), payload = excluded.payload`;
    } else if (body.step === "probe") {
      await sql`insert into raw.deezer_track_search (name_key, query, payload) values (${r.key}, ${r.query}, ${payload})
        on conflict (name_key) do update set query = excluded.query, fetched_at = now(), payload = excluded.payload`;
    } else if (body.step === "albums") {
      await sql`insert into raw.deezer_artist_albums (deezer_artist_id, payload) values (${r.key}::bigint, ${payload})
        on conflict (deezer_artist_id) do update set fetched_at = now(), payload = excluded.payload`;
    } else if (body.step === "tracks") {
      await sql`insert into raw.deezer_album_tracks (album_id, payload) values (${r.key}::bigint, ${payload})
        on conflict (album_id) do update set fetched_at = now(), payload = excluded.payload`;
    } else {
      throw new Error(`unknown step ${body?.step}`);
    }
  }
  return { step: body.step, saved: rows.length, by };
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const url = new URL(req.url);
  const part = url.searchParams.get("part");
  const by = url.searchParams.get("by") ?? "manual";

  if (part === "deezer_todo") return Response.json(await deezerTodo(url.searchParams.get("since")));
  if (part === "deezer_save") {
    let body: any;
    try { body = await req.json(); } catch { return new Response("body must be JSON", { status: 400 }); }
    if (body?.step === "run") {          // the server's summary at the end of a run
      await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
        values ('deezer', ${by}, now(), ${body.status ?? "ok"}, ${sql.json(body.detail ?? {})})`;
      return Response.json({ status: "logged" });
    }
    return Response.json(await deezerSave(body, by));
  }
  if (part !== "trends") return new Response("expected ?part=trends, deezer_todo or deezer_save", { status: 400 });

  const [{ run_id }] = await sql`insert into raw.music_runs (part, run_by) values ('trends', ${by}) returning run_id`;
  try {
    const detail = await trends();
    const status = (detail as any).failed.length ? "partial" : "ok";
    await sql`update raw.music_runs set finished_at = now(), status = ${status}, detail = ${sql.json(detail)} where run_id = ${run_id}`;
    return Response.json({ run_id, status, ...detail });
  } catch (e) {
    const message = String((e as Error)?.message ?? e).slice(0, 500);
    await sql`update raw.music_runs set finished_at = now(), status = 'failed', detail = ${sql.json({ error: message })} where run_id = ${run_id}`;
    return Response.json({ run_id, status: "failed", error: message }, { status: 500 });
  }
});
