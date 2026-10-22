// Supabase Edge Function: the Load side of extract_tiktok_extras.py (sql/014_tiktok_extras.sql).
// The script runs where TikTok answers (GitHub Actions weekly; Vic's PC for tests) and has no
// database password, only NDN_CRON_SECRET.
//   GET  ?step=pages|sounds|comments|profiles|artist_videos|artist_sounds&limit=N  -> {items: [...]} what to fetch next
//        (artist_videos + artist_sounds: sql/026, the TikTok-first invite score; artist_sounds also counts
//        the tracked trending-song sounds of sql/028)
//   POST ?step=...  {rows: [...]}                          -> saves them (upsert)
//   POST ?step=run  {status, detail}                       -> run log row in raw.music_runs (part tiktok_extras)
// Same secret check as the other functions.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const phDate = () => new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);

async function todo(step: string, limit: number) {
  if (step === "pages") {          // new videos, plus videos under 30 days old not refreshed this week
    return await sql`
      select s.video_id from staging.tiktok_video_snapshot s
      left join raw.tiktok_video_page p using (video_id)
      where s.snapshot_date = (select max(snapshot_date) from staging.tiktok_video_snapshot)
        and (p.video_id is null or (s.published_at > now() - interval '30 days' and p.fetched_at < now() - interval '6 days'))
      order by p.video_id is not null, s.published_at desc limit ${limit}`;
  }
  if (step === "sounds") {         // every sound used, once per week
    return await sql`
      select v.music_id, min(v.sound_title) as title from staging.tiktok_video_page v
      left join raw.tiktok_sound_stats s on s.music_id = v.music_id and s.snapshot_date > ${phDate()}::date - 6
      where v.music_id is not null and s.music_id is null
      group by v.music_id order by count(*) desc limit ${limit}`;
  }
  if (step === "comments") {       // videos whose comment count grew since we last fetched them
    return await sql`
      select s.video_id, s.comments as expected from staging.tiktok_video_snapshot s
      left join raw.tiktok_comment_fetch f using (video_id)
      where s.snapshot_date = (select max(snapshot_date) from staging.tiktok_video_snapshot)
        and s.comments > 0 and s.comments > coalesce(f.count_at_fetch, -1)
      order by s.comments - coalesce(f.count_at_fetch, 0) desc limit ${limit}`;
  }
  if (step === "profiles") {       // listed accounts + auto-found artist accounts, once per week
    return await sql`
      with accts as (
        select handle from raw.tiktok_accounts where active
        union
        select c.handle from staging.tiktok_artist_account_candidate c
        where not exists (select 1 from raw.tiktok_accounts a where a.handle = c.handle)
        union   -- sql/033: every artist account found any way (Vic's list, Instagram link, TikTok search, ...)
        select handle from staging.artist_tiktok_account
      )
      select a.handle from accts a
      left join raw.tiktok_account_snapshot s on s.handle = a.handle and s.snapshot_date > ${phDate()}::date - 6
      where s.handle is null limit ${limit}`;
  }
  if (step === "artist_videos") {
    // known artist accounts weekly; for artists without one, their Instagram username as a guess (kept only when the
    // display name matches, staging.artist_tiktok_account). Unmatched or missing guesses: tried again after 30 days.
    return await sql`
      with h as (
        select handle, null::text as guess_for from raw.tiktok_accounts where role = 'artist' and active
        union
        select c.handle, null from staging.tiktok_artist_account_candidate c
        where not exists (select 1 from raw.tiktok_accounts a where a.handle = c.handle)
        union
        select tiktok_handle, null from raw.spotify_artists where active and tiktok_handle is not null
        union   -- sql/033: accounts linked in the artist's Instagram or found by TikTok search
        select handle, null from staging.artist_tiktok_account
        where found_by in ('linked in their Instagram', 'TikTok search, name checked')
        union
        select ig.username, ig.spotify_id from staging.artist_instagram ig
        join raw.spotify_artists a on a.spotify_id = ig.spotify_id and a.active
        where ig.username is not null
          and not exists (select 1 from staging.artist_tiktok_account t
                          where t.spotify_id = ig.spotify_id and t.found_by <> 'Instagram name, checked')
      ), one as (
        select distinct on (handle) handle, guess_for from h order by handle, guess_for nulls first
      )
      select o.handle, o.guess_for from one o
      left join raw.tiktok_artist_video_fetch f using (handle)
      where f.handle is null
         or (f.fetched_at < now() - interval '6 days'
             and (o.guess_for is null or exists (select 1 from staging.artist_tiktok_account t where t.handle = o.handle)))
         or f.fetched_at < now() - interval '30 days'
      order by o.guess_for is not null, f.fetched_at nulls first limit ${limit}`;
  }
  if (step === "artist_sounds") {  // artists' own released songs (sound made in the last 3 years), once per week,
    // plus the tracked trending-song sounds, official + fan uploads (sql/028; the home server counts any left over)
    return await sql`
      with x as (
        select s.music_id, min(s.sound_title) as title, max(s.own_videos) as weight from staging.tiktok_artist_sound s
        where s.sound_created > ${phDate()}::date - 1096 group by s.music_id
        union all
        select s.music_id, min(s.title), 0 from staging.tiktok_trend_sound s
        join raw.tiktok_trend_song t using (song_key)
        where t.active and s.status in ('kept', 'unchecked') group by s.music_id
      )
      select x.music_id, min(x.title) as title from x
      left join raw.tiktok_sound_stats st on st.music_id = x.music_id and st.snapshot_date > ${phDate()}::date - 6
      where st.music_id is null
      group by x.music_id order by max(x.weight) desc limit ${limit}`;
  }
  throw new Error(`unknown step ${step}`);
}

async function save(step: string, rows: any[]) {
  const day = phDate();
  for (const r of rows) {
    if (step === "pages") {
      await sql`insert into raw.tiktok_video_page (video_id, item) values (${r.video_id}, ${sql.json(r.item)})
        on conflict (video_id) do update set fetched_at = now(), item = excluded.item`;
    } else if (step === "artist_videos") {
      await sql`insert into raw.tiktok_artist_video_fetch (handle, guess_for, found, nickname, videos)
        values (${r.handle}, ${r.guess_for ?? null}, ${!!r.found}, ${r.nickname ?? null}, ${(r.videos ?? []).length})
        on conflict (handle) do update set fetched_at = now(), guess_for = excluded.guess_for, found = excluded.found,
          nickname = excluded.nickname, videos = excluded.videos`;
      await sql`insert into raw.tiktok_artist_video (handle, video_id, posted_at, views, music)
        select ${r.handle}, x->>'video_id', to_timestamp((x->>'posted_at')::bigint), (x->>'views')::bigint, x->'music'
        from jsonb_array_elements(${sql.json(r.videos ?? [])}) x where x->>'video_id' is not null
        on conflict (handle, video_id) do update set fetched_at = now(), views = excluded.views, music = excluded.music`;
    } else if (step === "sounds" || step === "artist_sounds") {
      await sql`insert into raw.tiktok_sound_stats (music_id, snapshot_date, payload) values (${r.music_id}, ${day}, ${sql.json(r.payload)})
        on conflict (music_id, snapshot_date) do update set fetched_at = now(), payload = excluded.payload`;
    } else if (step === "comments") {
      // one statement per video (a video can have 4,000+ comments)
      await sql`insert into raw.tiktok_comments (cid, video_id, comment)
        select distinct on (x->>'cid') x->>'cid', ${r.video_id}, x from jsonb_array_elements(${sql.json(r.comments ?? [])}) x
        where x->>'cid' is not null
        on conflict (cid) do update set fetched_at = now(), comment = excluded.comment`;
      await sql`insert into raw.tiktok_comment_fetch (video_id, count_at_fetch, saved) values (${r.video_id}, ${r.expected}, ${(r.comments ?? []).length})
        on conflict (video_id) do update set fetched_at = now(), count_at_fetch = excluded.count_at_fetch, saved = excluded.saved`;
    } else if (step === "profiles") {
      await sql`insert into raw.tiktok_account_snapshot (handle, snapshot_date, payload) values (${r.handle}, ${day}, ${sql.json(r.payload)})
        on conflict (handle, snapshot_date) do update set fetched_at = now(), payload = excluded.payload`;
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
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 200) || 200, 2000);
      return Response.json({ step, items: await todo(step, limit) });
    }
    const body = await req.json();
    if (step === "run") {
      await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
        values ('tiktok_extras', ${by}, now(), ${body.status ?? "ok"}, ${sql.json(body.detail ?? {})})`;
      return Response.json({ status: "logged" });
    }
    return Response.json(await save(step, Array.isArray(body?.rows) ? body.rows : []));
  } catch (e) {
    return Response.json({ error: String((e as Error)?.message ?? e).slice(0, 500) }, { status: 500 });
  }
});
