// Supabase Edge Function: the Load side of extract_spotify.py (sql/015_spotify_kworb.sql).
// The script runs where Spotify answers (a headless browser) and has no database password,
// only NDN_CRON_SECRET.
//   GET  ?step=playlists|search|artists|kworb&limit=N  -> {items: [...]} what to fetch next
//        (playlists + chart/playlist artists in search: sql/026, invite candidates)
//   POST ?step=...  {rows: [...]}              -> saves them (upsert)
//   POST ?step=run  {status, detail}           -> run log row in raw.music_runs (part spotify)
// Same secret check as the other functions.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const phDate = () => new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);
const SURE = ["kworb_chart", "bio_link", "confirmed_by_song", "manual", "ph_chart", "viral_playlist"];   // used without Vic checking
const POOL = ["ph_chart", "viral_playlist"];   // invite candidates found on a chart/playlist, not NDN artists

async function todo(step: string, limit: number) {
  if (step === "playlists") {      // Spotify playlists listed in raw.spotify_playlists, once per week
    return await sql`
      select p.playlist_id, p.name from raw.spotify_playlists p
      where p.active and not exists (select 1 from raw.spotify_playlist_snapshot s where s.playlist_id = p.playlist_id
                                     and s.snapshot_date > ${phDate()}::date - 6)
      order by p.playlist_id limit ${limit}`;
  }
  if (step === "search") {
    // NDN artists (single names, not "A & B" credits) and TikTok artist accounts outside the NDN
    // list, with no Spotify artist yet. Names without a match are searched again after 30 days.
    return await sql`
      with parts as (
        select a.name_key, min(a.name) as name, array_agg(distinct a.credit_key) as credit_keys
        from staging.ndn_artist a
        where a.part_no > 0 or not exists (select 1 from staging.ndn_artist b where b.credit_key = a.credit_key and b.part_no > 0)
        group by a.name_key
      ), pool as (
        -- artists on the PH weekly chart (last 8 weeks) or the latest playlist snapshot: the id is known already
        select distinct on (id) id, kind from (
          select unnest(spotify_artist_ids) as id, 'ph_chart' as kind, 1 as pri from staging.trend_spotify_ph
          where snapshot_date >= current_date - 56
          union all
          select unnest(artist_ids), 'viral_playlist', 2 from staging.spotify_playlist_track
          where snapshot_date = (select max(snapshot_date) from staging.spotify_playlist_track)
        ) x where id is not null order by id, pri
      ), names as (
        select p.name_key as query_key, p.name_key, null::text as tiktok_handle, p.name as query,
               coalesce((select array_agg(distinct v.song) from mart.dim_video v
                         where v.platform = 'YouTube' and v.song is not null
                           and staging.name_key(btrim(regexp_replace(v.artist, '^[-—–\\s]+', ''))) = any(p.credit_keys)), '{}') as songs,
               (select min(c.spotify_artist_ids[1]) from staging.trend_spotify_ph c where staging.name_key(c.artist) = p.name_key) as chart_id,
               null::text as chart_type
        from parts p
        union all
        select 'tiktok:' || t.handle, null, t.handle, split_part(t.note, ';', 1), '{}', null, null
        from raw.tiktok_accounts t where t.role = 'artist' and t.active and t.artist_name_key is null
        union all
        select 'chart:' || p.id, null, null, p.id, '{}', p.id, p.kind from pool p
      )
      select n.* from names n
      left join raw.spotify_search s using (query_key)
      where not exists (select 1 from raw.spotify_artists a
                        where a.artist_name_key = n.name_key or a.tiktok_handle = n.tiktok_handle
                           or (n.chart_type is not null and a.spotify_id = n.chart_id))
        and (s.query_key is null or (s.pick is null and s.fetched_at < now() - interval '30 days'))
      order by n.query limit ${limit}`;
  }
  if (step === "artists" || step === "kworb") {    // active artists not fetched in the last 6 days
    // chart/playlist candidates with under 30% PH listeners in their top 5 cities (not OPM) are skipped after
    // their first artist page; the invite view needs 50%, so the 30-50% band is still refreshed
    const t = step === "artists" ? sql`raw.spotify_artist_snapshot` : sql`raw.kworb_artist_songs`;
    return await sql`
      select a.spotify_id, a.name from raw.spotify_artists a
      where a.active and not exists (select 1 from ${t} s where s.spotify_id = a.spotify_id
                                     and s.snapshot_date > ${phDate()}::date - 6)
        and not (a.match_type = any(${POOL})
                 and exists (select 1 from staging.spotify_artist_ph_share x where x.spotify_id = a.spotify_id and x.ph_share < 0.3))
      order by a.spotify_id limit ${limit}`;
  }
  throw new Error(`unknown step ${step}`);
}

async function save(step: string, rows: any[]) {
  const day = phDate();
  for (const r of rows) {
    if (step === "search") {
      await sql`insert into raw.spotify_search (query_key, query, results, pick)
        values (${r.query_key}, ${r.query}, ${sql.json(r.results ?? [])}, ${r.pick ? sql.json(r.pick) : null})
        on conflict (query_key) do update set fetched_at = now(), query = excluded.query,
          results = excluded.results, pick = excluded.pick`;
      const p = r.pick;
      if (p?.spotify_id) {
        // chart/playlist candidates get their own name as the key (to match TikTok accounts and fan requests)
        const nameKey = r.name_key ?? (POOL.includes(p.match_type) ? p.name : null);
        await sql`insert into raw.spotify_artists (spotify_id, name, artist_name_key, tiktok_handle, match_type, evidence, active)
          values (${p.spotify_id}, ${p.name}, nullif(staging.name_key(${nameKey}), ''),
                  ${r.tiktok_handle ?? null}, ${p.match_type}, ${p.evidence ?? null}, ${SURE.includes(p.match_type)})
          on conflict (spotify_id) do nothing`;
      }
    } else if (step === "playlists") {
      await sql`insert into raw.spotify_playlist_snapshot (playlist_id, snapshot_date, payload)
        values (${r.playlist_id}, ${day}, ${sql.json(r.payload)})
        on conflict (playlist_id, snapshot_date) do update set fetched_at = now(), payload = excluded.payload`;
    } else if (step === "artists") {
      await sql`insert into raw.spotify_artist_snapshot (spotify_id, snapshot_date, payload)
        values (${r.spotify_id}, ${day}, ${sql.json(r.payload)})
        on conflict (spotify_id, snapshot_date) do update set fetched_at = now(), payload = excluded.payload`;
    } else if (step === "kworb") {
      await sql`insert into raw.kworb_artist_songs (spotify_id, snapshot_date, found, kworb_updated, payload)
        values (${r.spotify_id}, ${day}, ${!!r.found}, ${r.kworb_updated ?? null}, ${r.payload ? sql.json(r.payload) : null})
        on conflict (spotify_id, snapshot_date) do update set fetched_at = now(), found = excluded.found,
          kworb_updated = excluded.kworb_updated, payload = excluded.payload`;
    } else {
      throw new Error(`unknown step ${step}`);
    }
  }
  return { step, saved: rows.length };
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
  try {
    if (req.method === "GET") {
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 500) || 500, 2000);
      return Response.json({ step, items: await todo(step, limit) });
    }
    const body = await req.json();
    if (step === "run") {
      await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
        values ('spotify', ${by}, now(), ${body.status ?? "ok"}, ${sql.json(body.detail ?? {})})`;
      return Response.json({ status: "logged" });
    }
    return Response.json(await save(step, Array.isArray(body?.rows) ? body.rows : []));
  } catch (e) {
    return Response.json({ error: String((e as Error)?.message ?? e).slice(0, 500) }, { status: 500 });
  }
});
