// Supabase Edge Function: the Load side of extract_spotify.py (sql/015_spotify_kworb.sql).
// The script runs where Spotify answers (a headless browser) and has no database password,
// only NDN_CRON_SECRET.
//   GET  ?step=search|artists|kworb&limit=N  -> {items: [...]} what to fetch next
//   POST ?step=...  {rows: [...]}              -> saves them (upsert)
//   POST ?step=run  {status, detail}           -> run log row in raw.music_runs (part spotify)
// Same secret check as the other functions.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const phDate = () => new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);
const SURE = ["kworb_chart", "bio_link", "confirmed_by_song", "manual"];   // used without Vic checking

async function todo(step: string, limit: number) {
  if (step === "search") {
    // NDN artists (single names, not "A & B" credits) and TikTok artist accounts outside the NDN
    // list, with no Spotify artist yet. Names without a match are searched again after 30 days.
    return await sql`
      with parts as (
        select a.name_key, min(a.name) as name, array_agg(distinct a.credit_key) as credit_keys
        from staging.ndn_artist a
        where a.part_no > 0 or not exists (select 1 from staging.ndn_artist b where b.credit_key = a.credit_key and b.part_no > 0)
        group by a.name_key
      ), names as (
        select p.name_key as query_key, p.name_key, null::text as tiktok_handle, p.name as query,
               coalesce((select array_agg(distinct v.song) from mart.dim_video v
                         where v.platform = 'YouTube' and v.song is not null
                           and staging.name_key(btrim(regexp_replace(v.artist, '^[-—–\\s]+', ''))) = any(p.credit_keys)), '{}') as songs,
               (select min(c.spotify_artist_ids[1]) from staging.trend_spotify_ph c where staging.name_key(c.artist) = p.name_key) as chart_id
        from parts p
        union all
        select 'tiktok:' || t.handle, null, t.handle, split_part(t.note, ';', 1), '{}', null
        from raw.tiktok_accounts t where t.role = 'artist' and t.active and t.artist_name_key is null
      )
      select n.* from names n
      left join raw.spotify_search s using (query_key)
      where not exists (select 1 from raw.spotify_artists a
                        where a.artist_name_key = n.name_key or a.tiktok_handle = n.tiktok_handle)
        and (s.query_key is null or (s.pick is null and s.fetched_at < now() - interval '30 days'))
      order by n.query limit ${limit}`;
  }
  if (step === "artists" || step === "kworb") {    // active artists not fetched in the last 6 days
    const t = step === "artists" ? sql`raw.spotify_artist_snapshot` : sql`raw.kworb_artist_songs`;
    return await sql`
      select a.spotify_id, a.name from raw.spotify_artists a
      where a.active and not exists (select 1 from ${t} s where s.spotify_id = a.spotify_id
                                     and s.snapshot_date > ${phDate()}::date - 6)
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
        await sql`insert into raw.spotify_artists (spotify_id, name, artist_name_key, tiktok_handle, match_type, evidence, active)
          values (${p.spotify_id}, ${p.name}, ${r.name_key ?? null}, ${r.tiktok_handle ?? null}, ${p.match_type},
                  ${p.evidence ?? null}, ${SURE.includes(p.match_type)})
          on conflict (spotify_id) do nothing`;
      }
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
