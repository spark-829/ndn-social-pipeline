// Supabase Edge Function: the Load side of the trending-OPM-sounds setup (sql/028_tiktok_trending_sounds.sql).
// Callers: the home server's seed_trending.py (once) and trending_weekly.py (Mondays). They have no database
// password, only NDN_CRON_SECRET. Claude does not fetch TikTok; these scripts are Vic's crawler.
//   GET  ?step=votes&limit=N    -> {items: [{song_key, music_id, song, artist}]}  sounds waiting for a caption vote
//   GET  ?step=counts&limit=N   -> {items: [{music_id}]}  tracked sounds not counted in the last 6 days
//   GET  ?step=top30            -> the OPM top 30 of the three Spotify playlists (sql/029)
//   GET  ?step=need_accounts    -> top-30 artists with no TikTok account yet (sql/033)
//   POST ?step=accounts {rows: [{spotify_id, handle, nickname, followers, verified}]}  TikTok user-search candidates
//   POST ?step=search   {rows: [{song_key, song, artist, spotify_id, sounds: [{music_id, title, author, videos, credited}]}]}
//                       Sounds-tab search results (top30_tiktok.py, every 3 days): sounds + their counts today;
//                       sounds[].from = video_search reserved for sounds found through videos (sql/030, unused)
//   POST ?step=seed     {songs: [...], sounds: [...], counts: [{music_id, snapshot_date, payload}]}
//   POST ?step=links    {rows: [{song, artist, music_id}]}   fan-sound links from Vic's Google Sheet
//   POST ?step=votes    {rows: [{song_key, music_id, captions, name_artist, name_song, payload?}]}
//   POST ?step=counts   {rows: [{music_id, payload}]}        payload = musicInfo from the sound page
//   POST ?step=hashtags {payload}  Creative Center top 100 PH hashtags, logged in -> raw.trend_responses
//   POST ?step=refresh             mart.weekly_tiktok_trending(): this week's candidates into the tracked list
//   POST ?step=run      {status, detail}  run log row in raw.music_runs (part tiktok_trending)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const phDate = () => new Date(Date.now() + 8 * 3600_000).toISOString().slice(0, 10);
const songKey = async (artist: string, song: string) =>
  (await sql`select staging.name_key(${artist}) || '|' || staging.title_key(${song}) as k`)[0].k as string;

async function todo(step: string, limit: number) {
  if (step === "votes") {          // not credited, never voted (Vic's new links + sounds-tab sounds the vote missed)
    return await sql`
      select s.song_key, s.music_id, t.song, t.artist from raw.tiktok_trend_sound s
      join raw.tiktok_trend_song t using (song_key)
      where t.active and not s.credited and s.voted_at is null and s.status_by_vic is null
      order by s.added_from = 'vic_sheet' desc, s.added_at limit ${limit}`;
  }
  if (step === "top30") {          // sql/029: the OPM top 30 of the three Spotify playlists, for the title search
    return await sql`select song_key, song, artist, spotify_id, rank from staging.invite_top30 order by rank limit ${limit}`;
  }
  if (step === "need_accounts") {  // sql/033: top-30 artists with no TikTok account yet, for the user search
    return await sql`
      select distinct t.spotify_id, t.artist from staging.invite_top30 t
      where not exists (select 1 from staging.artist_tiktok_account a where a.spotify_id = t.spotify_id)
        and not exists (select 1 from raw.artist_tiktok_found f
                        where f.spotify_id = t.spotify_id and f.found_at > now() - interval '6 days')
      limit ${limit}`;
  }
  if (step === "counts") {         // kept or unchecked sounds of active songs, once per week
    return await sql`
      select distinct s.music_id from staging.tiktok_trend_sound s
      join raw.tiktok_trend_song t using (song_key)
      where t.active and s.status in ('kept', 'unchecked')
        and not exists (select 1 from raw.tiktok_sound_stats st
                        where st.music_id = s.music_id and st.snapshot_date > ${phDate()}::date - 6)
      limit ${limit}`;
  }
  throw new Error(`unknown step ${step}`);
}

async function saveCount(musicId: string, day: string, payload: unknown, keepExisting = false) {
  if (keepExisting) {
    await sql`insert into raw.tiktok_sound_stats (music_id, snapshot_date, payload)
      values (${musicId}, ${day}, ${sql.json(payload as any)}) on conflict (music_id, snapshot_date) do nothing`;
  } else {
    await sql`insert into raw.tiktok_sound_stats (music_id, snapshot_date, payload)
      values (${musicId}, ${day}, ${sql.json(payload as any)})
      on conflict (music_id, snapshot_date) do update set fetched_at = now(), payload = excluded.payload`;
  }
}

async function save(step: string, body: any) {
  const day = phDate();
  if (step === "seed") {
    for (const s of body.songs ?? []) {
      const k = await songKey(s.artist, s.song);
      await sql`insert into raw.tiktok_trend_song (song_key, song, artist, spotify_id, found_in, first_seen, last_seen)
        values (${k}, ${s.song}, ${s.artist},
                (select spotify_id from raw.spotify_artists where artist_name_key = staging.name_key(${s.artist})
                 order by active desc limit 1),
                ${s.found_in}, ${s.seen}, ${s.seen})
        on conflict (song_key) do update set found_in = array(select distinct x from
          unnest(raw.tiktok_trend_song.found_in || excluded.found_in) x order by 1)`;
      for (const x of s.sounds ?? []) {
        await sql`insert into raw.tiktok_trend_sound (song_key, music_id, title, author, added_from, credited,
                                                      captions, name_artist, name_song, voted_at)
          values (${k}, ${x.music_id}, ${x.title}, ${x.author}, 'sounds_tab', ${!!x.credited},
                  ${x.captions ?? null}, ${x.name_artist ?? null}, ${x.name_song ?? null}, ${x.voted_at ?? null})
          on conflict (song_key, music_id) do nothing`;
      }
    }
    // baseline counts: a real weekly count of the same day wins
    for (const c of body.counts ?? []) await saveCount(c.music_id, c.snapshot_date, c.payload, true);
    return { step, songs: (body.songs ?? []).length, counts: (body.counts ?? []).length };
  }
  if (step === "search") {         // sql/029: one Sounds-tab search per top-30 song (top30_tiktok.py, every 3 days)
    let sounds = 0;
    for (const r of body.rows ?? []) {
      await sql`insert into raw.tiktok_trend_song (song_key, song, artist, spotify_id, found_in)
        values (${r.song_key}, ${r.song}, ${r.artist}, ${r.spotify_id ?? null}, '{top30}')
        on conflict (song_key) do update set last_seen = ${day}::date, active = true,
          found_in = array(select distinct x from unnest(raw.tiktok_trend_song.found_in || '{top30}'::text[]) x order by 1)`;
      for (const x of r.sounds ?? []) {
        // from: 'sounds_tab' (Sounds-tab search, has a count) or 'video_search' (sound used by videos about the song,
        // sql/030: fan uploads; counted later by the caption vote's sound-page visit)
        const from = x.from === "video_search" ? "video_search" : "sounds_tab";
        await sql`insert into raw.tiktok_trend_sound (song_key, music_id, title, author, added_from, credited)
          values (${r.song_key}, ${x.music_id}, ${x.title}, ${x.author}, ${from}, ${!!x.credited})
          on conflict (song_key, music_id) do update set credited = raw.tiktok_trend_sound.credited or excluded.credited`;
        if (x.videos != null) {
          await saveCount(x.music_id, day, { music: { id: x.music_id, title: x.title, authorName: x.author },
                                            stats: { videoCount: x.videos }, source: "sounds_tab_search" }, true);
        }
        sounds++;
      }
    }
    return { step, songs: (body.rows ?? []).length, sounds };
  }
  if (step === "accounts") {       // sql/033: TikTok user-search candidates (the account view checks the name)
    let saved = 0;
    for (const r of body.rows ?? []) {
      await sql`insert into raw.artist_tiktok_found (spotify_id, handle, nickname, followers, verified)
        values (${r.spotify_id}, ${String(r.handle).toLowerCase()}, ${r.nickname ?? null}, ${r.followers ?? null},
                ${r.verified ?? null})
        on conflict (spotify_id, handle) do update set found_at = now(), nickname = excluded.nickname,
          followers = excluded.followers, verified = excluded.verified`;
      if (r.followers != null) {     // a follower count for today, in the profile snapshot format
        await sql`insert into raw.tiktok_account_snapshot (handle, snapshot_date, payload)
          values (${String(r.handle).toLowerCase()}, ${day},
                  ${sql.json({ user: { uniqueId: r.handle, nickname: r.nickname }, statsV2: { followerCount: r.followers },
                               source: "tiktok_user_search" })})
          on conflict (handle, snapshot_date) do nothing`;
      }
      saved++;
    }
    return { step, saved };
  }
  if (step === "links") {
    let added = 0;
    const unknown: string[] = [];
    for (const r of body.rows ?? []) {
      const k = await songKey(r.artist, r.song);
      const [song] = await sql`select song_key from raw.tiktok_trend_song where song_key = ${k}`;
      if (!song) {             // a song Vic typed that is not tracked yet: add it
        await sql`insert into raw.tiktok_trend_song (song_key, song, artist, spotify_id, found_in)
          values (${k}, ${r.song}, ${r.artist},
                  (select spotify_id from raw.spotify_artists where artist_name_key = staging.name_key(${r.artist})
                   order by active desc limit 1), '{vic_sheet}')`;
        unknown.push(`${r.song} / ${r.artist}`);
      }
      const res = await sql`insert into raw.tiktok_trend_sound (song_key, music_id, added_from)
        values (${k}, ${r.music_id}, 'vic_sheet') on conflict (song_key, music_id) do nothing`;
      added += res.count;
    }
    return { step, rows: (body.rows ?? []).length, added, new_songs: unknown };
  }
  if (step === "votes") {
    for (const r of body.rows ?? []) {
      const m = r.payload?.music ?? {};
      await sql`update raw.tiktok_trend_sound
        set captions = ${r.captions}, name_artist = ${r.name_artist}, name_song = ${r.name_song}, voted_at = now(),
            title = coalesce(title, ${m.title ?? null}), author = coalesce(author, ${m.authorName ?? null})
        where song_key = ${r.song_key} and music_id = ${r.music_id}`;
      if (r.payload?.stats) await saveCount(r.music_id, day, r.payload);
    }
    return { step, saved: (body.rows ?? []).length };
  }
  if (step === "counts") {
    for (const r of body.rows ?? []) await saveCount(r.music_id, day, r.payload);
    return { step, saved: (body.rows ?? []).length };
  }
  if (step === "hashtags") {
    const items = body.payload?.items ?? [];
    await sql`insert into raw.trend_responses (source, chart, snapshot_date, url, payload)
      values ('tiktok_cc_login', 'hashtag_7d_all', ${day},
              'https://ads.tiktok.com/CreativeOne/KnowledgeAPI/GetHashtagList', ${sql.json(body.payload)})
      on conflict (source, chart, snapshot_date) do update set fetched_at = now(), payload = excluded.payload`;
    return { step, hashtags: items.length };
  }
  if (step === "refresh") {
    const [{ n }] = await sql`select mart.weekly_tiktok_trending() as n`;
    return { step, candidates: n };
  }
  if (step === "run") {
    await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
      values ('tiktok_trending', ${body.by ?? "server"}, now(), ${body.status}, ${sql.json(body.detail ?? {})})`;
    return { step };
  }
  throw new Error(`unknown step ${step}`);
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const url = new URL(req.url);
  const step = url.searchParams.get("step") ?? "";
  try {
    if (req.method === "GET") {
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 200) || 200, 2000);
      return Response.json({ step, items: await todo(step, limit) });
    }
    return Response.json(await save(step, await req.json().catch(() => ({}))));
  } catch (e) {
    return Response.json({ step, error: String(e) }, { status: 500 });
  }
});
