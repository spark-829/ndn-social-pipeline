-- 028: trending OPM sounds on TikTok (TIKTOK_TRENDING_PLAN.md "Research 2026-10-23", 3-part design).
-- 1. Candidates (automatic, weekly): OPM songs on kworb's Spotify PH daily chart (top 50, rising or new), Viral Hits
--    PH, new releases of pool artists (Deezer catalogs), and song titles in the logged-in Creative Center top 100 PH
--    hashtags. Creative Center top videos: no PH data (tested 2026-10-23), so not a source.
-- 2. Sounds per song: seeded from the 2026-10-22 Sounds-tab search (155 songs, official + version sounds, their
--    video counts = the baseline), plus fan-sound links Vic pastes in the Google Sheet "NDN fan sounds". A sound counts
--    for a song when TikTok credits the artist, or when 2+ captions on its sound page name the artist (caption vote;
--    Vic's links also pass with 2+ captions naming the song). Vic's hand check (status_by_vic) overrides both.
-- 3. Trending number: videos added in 7 days per song, summed over its counted sounds, from the weekly sound counts
--    (raw.tiktok_sound_stats; counted by weekly.yml's artist_sounds step and the home server's trending_weekly.py).
--    Feeds mart.invite_candidates (tt_song_videos) and Power BI "Trending OPM sounds this week".
-- Writes come through the Edge Function tiktok-trending (home server: seed_trending.py, trending_weekly.py).

------------------------------------------------------------------ raw
create table if not exists raw.tiktok_trend_song (
  song_key         text primary key,                -- staging.name_key(artist) || '|' || staging.title_key(song)
  song             text not null,
  artist           text not null,
  spotify_id       text,                            -- main artist
  spotify_track_id text,
  found_in         text[] not null default '{}',    -- kworb_daily, viral_hits, new_release, cc_hashtag, sounds_tab, vic_sheet
  first_seen       date not null default (now() at time zone 'Asia/Manila')::date,
  last_seen        date not null default (now() at time zone 'Asia/Manila')::date,
  active           boolean not null default true,   -- Vic: false = stop tracking
  note             text
);

create table if not exists raw.tiktok_trend_sound (
  song_key      text not null references raw.tiktok_trend_song on delete cascade,
  music_id      text not null,
  title         text,
  author        text,
  added_from    text not null check (added_from in ('sounds_tab', 'vic_sheet')),
  credited      boolean not null default false,     -- TikTok names the artist (sound author or "Contains music from")
  captions      int,                                -- caption vote: captions read on the sound page
  name_artist   int,                                --   ... naming the artist
  name_song     int,                                --   ... naming the song
  voted_at      timestamptz,
  status_by_vic text check (status_by_vic in ('kept', 'dropped')),
  added_at      timestamptz not null default now(),
  primary key (song_key, music_id)
);
create index if not exists tiktok_trend_sound_music on raw.tiktok_trend_sound (music_id);

------------------------------------------------------------------ staging
-- kworb Spotify PH daily chart (saved by music-weekly every Monday, next to the weekly chart).
-- Cells: pos, P+, artist - title, days, peak, (x?), streams, streams+, 7day, 7day+, total.
create or replace view staging.trend_spotify_ph_daily as
with rows as (
  select r.snapshot_date,
         to_date(substring(r.body, 'Philippines - (\d{4}/\d{2}/\d{2})'), 'YYYY/MM/DD') as chart_date,
         split_part(tr.tr, '</tr>', 1) as tr
  from raw.trend_responses r, lateral regexp_split_to_table(r.body, '<tr[ >]') tr(tr)
  where r.source = 'kworb' and r.chart = 'spotify_ph_daily'
), cells as (
  select snapshot_date, chart_date,
         array(select substring(x.c, '<td[^>]*>(.*)$') from regexp_split_to_table(tr, '</td>') with ordinality x(c, n)
               where x.c like '%<td%' order by x.n) as td
  from rows where tr like '%<td%'
)
select snapshot_date, chart_date, td[1]::int as rank,
       regexp_replace(split_part(td[3], '</a> - <a', 1), '<[^>]+>', '', 'g')                 as artist,
       substring(td[3], 'track/([A-Za-z0-9]+)\.html')                                       as spotify_track_id,
       substring(td[3], 'track/[A-Za-z0-9]+\.html">([^<]*)</a>')                            as song,
       array(select a[1] from regexp_matches(td[3], 'artist/([A-Za-z0-9]+)\.html', 'g') a)   as spotify_artist_ids,
       td[4]::int                                                                           as days_on_chart,
       replace(td[7], ',', '')::bigint                                                      as streams,
       nullif(replace(replace(td[10], ',', ''), '+', ''), '')::bigint                       as streams_7d_change
from cells where td[1] ~ '^\d+$';

-- Creative Center top 100 PH hashtags, last 7 days, logged in (trending_weekly.py; logged out gives 3).
create or replace view staging.trend_tiktok_hashtag_login as
select r.snapshot_date, (h->>'rankIndex')::int as rank, h->>'hashtagName' as hashtag,
       (h->>'publishCnt')::bigint as posts, (h->>'vv')::bigint as views
from raw.trend_responses r, lateral jsonb_array_elements(r.payload->'items') h
where r.source = 'tiktok_cc_login';

-- OPM rule (same as the invite pool): artist has 90%+ of Spotify top-city listeners in PH, or is in Vic's pool
-- (NDN performer / Vic's list).
create or replace view staging.opm_artist as
select a.spotify_id from raw.spotify_artists a
left join staging.spotify_artist_ph_share ps using (spotify_id)
where a.active and (a.match_type not in ('ph_chart', 'viral_playlist') or ps.ph_share >= 0.9);

-- New releases must also be on the artist's own Spotify page (kworb, matched by Spotify id) with 1,000+ daily streams:
-- matching Deezer catalogs by name alone pulled in namesakes (Turkish "Yno", "Lynx") and whole old catalogs (2026-10-23).
-- Hashtags are matched against every candidate title and the pool's Spotify songs.
create or replace view staging.tiktok_trend_candidate as
with pool_songs as (
  select a.name as artist, ks.title as song, ks.spotify_id, ks.track_id
  from staging.kworb_song ks
  join raw.spotify_artists a using (spotify_id)
  join staging.opm_artist o using (spotify_id)
  where ks.daily_streams >= 1000
    and ks.snapshot_date = (select max(x.snapshot_date) from staging.kworb_song x where x.spotify_id = ks.spotify_id)
), kd as (
  select k.* from staging.trend_spotify_ph_daily k
  where k.snapshot_date = (select max(snapshot_date) from staging.trend_spotify_ph_daily)
    and k.spotify_artist_ids[1] in (select spotify_id from staging.opm_artist)
    and (k.rank <= 50 or k.streams_7d_change > 0 or k.days_on_chart <= 14)
), vh as (
  select t.* from staging.spotify_playlist_track t
  where t.playlist = 'Viral Hits Philippines'
    and t.snapshot_date = (select max(snapshot_date) from staging.spotify_playlist_track where playlist = 'Viral Hits Philippines')
    and t.artist_ids[1] in (select spotify_id from staging.opm_artist)
), nr as (
  select distinct p.* from pool_songs p
  join staging.music_catalog_status m
    on staging.name_key(m.artist) = staging.name_key(p.artist) and m.title_key = staging.title_key(p.song)
  where m.first_release >= current_date - 28
), ht as (
  select hashtag from staging.trend_tiktok_hashtag_login
  where snapshot_date = (select max(snapshot_date) from staging.trend_tiktok_hashtag_login)
), c as (
  select k.artist, k.song, k.spotify_artist_ids[1] as spotify_id, k.spotify_track_id, 'kworb_daily' as src from kd k
  union all
  select t.artists[1], t.song, t.artist_ids[1], t.track_id, 'viral_hits' from vh t
  union all
  select n.artist, n.song, n.spotify_id, n.track_id, 'new_release' from nr n
), c2 as (
  select * from c
  union all  -- 6+ letters so #love etc. don't match
  select x.artist, x.song, x.spotify_id, x.spotify_track_id, 'cc_hashtag'
  from (select artist, song, spotify_id, spotify_track_id from c
        union select artist, song, spotify_id, track_id from pool_songs) x
  join ht on ht.hashtag = staging.title_key(x.song)
  where length(staging.title_key(x.song)) >= 6
)
select staging.name_key(min(artist)) || '|' || staging.title_key(song) as song_key,
       min(song) as song, min(artist) as artist, min(spotify_id) as spotify_id, min(spotify_track_id) as spotify_track_id,
       array_agg(distinct src order by src) as found_in
from c2
where staging.title_key(song) <> ''
group by spotify_id, staging.title_key(song);

-- Each tracked sound with its status: credited > Vic's check > caption vote.
create or replace view staging.tiktok_trend_sound as
select s.song_key, s.music_id, s.title, s.author, s.added_from, s.credited, s.captions, s.name_artist, s.name_song,
       s.voted_at, s.status_by_vic,
       coalesce(s.status_by_vic,
                case when s.credited then 'kept'
                     when s.voted_at is null then 'unchecked'
                     when s.name_artist >= 2 or (s.added_from = 'vic_sheet' and s.name_song >= 2) then 'kept'
                     else 'dropped' end) as status,
       case when s.status_by_vic is not null then 'Vic checked it'
            when s.credited then 'TikTok credits the artist'
            when s.voted_at is null then 'caption check not run yet'
            else s.name_artist || ' of ' || s.captions || ' captions name the artist, '
                 || s.name_song || ' name the song' end as why,
       'https://www.tiktok.com/music/x-' || s.music_id as link
from raw.tiktok_trend_sound s;

-- Videos added per sound in about a week: latest count vs the count 5-14 days before it, scaled to 7 days.
-- Reads raw.tiktok_sound_stats directly so the lookup back uses its primary key (the staging view made this 0.5 s).
create or replace view staging.tiktok_sound_week as
with l as (
  select distinct on (music_id) music_id, snapshot_date as d, (payload->'stats'->>'videoCount')::bigint as v
  from raw.tiktok_sound_stats where payload->'stats'->>'videoCount' is not null
  order by music_id, snapshot_date desc
)
select l.music_id, l.d as counted_on, l.v as videos, p.d as before_date, p.v as videos_before,
       case when p.v is not null then round((l.v - p.v) * 7.0 / (l.d - p.d))::bigint end as added_7d
from l
left join lateral (select s.snapshot_date as d, (s.payload->'stats'->>'videoCount')::bigint as v
                   from raw.tiktok_sound_stats s
                   where s.music_id = l.music_id and s.snapshot_date between l.d - 14 and l.d - 5
                     and s.payload->'stats'->>'videoCount' is not null
                   order by abs((l.d - 7) - s.snapshot_date), s.snapshot_date limit 1) p on true;

-- Per tracked song: kept sounds summed (official + fan uploads).
create or replace view staging.tiktok_trend_song_week as
select t.song_key, t.song, t.artist, t.spotify_id, staging.title_key(t.song) as title_key, t.found_in,
       t.first_seen, t.last_seen,
       sum(w.videos)   filter (where s.status = 'kept')                          as videos,
       sum(w.added_7d) filter (where s.status = 'kept')                          as added_7d,
       count(*)        filter (where s.status = 'kept')                          as sounds_kept,
       count(*)        filter (where s.status = 'kept' and w.added_7d is not null) as sounds_with_gain,
       count(*)        filter (where s.status = 'kept' and not s.credited)       as fan_sounds_kept,
       count(*)        filter (where s.status = 'unchecked')                     as sounds_unchecked,
       max(w.counted_on) filter (where s.status = 'kept')                        as counted_on,
       (array_agg(s.music_id order by coalesce(w.added_7d, -1) desc, w.videos desc nulls last)
          filter (where s.status = 'kept'))[1]                                   as top_music_id
from raw.tiktok_trend_song t
left join staging.tiktok_trend_sound s using (song_key)
left join staging.tiktok_sound_week w using (music_id)
where t.active
group by t.song_key;

------------------------------------------------------------------ mart
-- Weekly: add this week's candidates to the tracked list (keeps first_seen, adds sources).
create or replace function mart.weekly_tiktok_trending() returns int language sql as $$
  with up as (
    insert into raw.tiktok_trend_song (song_key, song, artist, spotify_id, spotify_track_id, found_in)
    select song_key, song, artist, spotify_id, spotify_track_id, found_in from staging.tiktok_trend_candidate
    on conflict (song_key) do update
      set last_seen = (now() at time zone 'Asia/Manila')::date,
          -- rows switched off automatically come back when they qualify again; Vic's own switch-offs stay off
          active = raw.tiktok_trend_song.active or coalesce(raw.tiktok_trend_song.note like 'auto-off%', false),
          spotify_id = coalesce(raw.tiktok_trend_song.spotify_id, excluded.spotify_id),
          spotify_track_id = coalesce(raw.tiktok_trend_song.spotify_track_id, excluded.spotify_track_id),
          found_in = array(select distinct x from unnest(raw.tiktok_trend_song.found_in || excluded.found_in) x order by 1)
    returning 1
  ) select count(*)::int from up
$$;

-- Power BI "Trending OPM sounds this week": songs seen as candidates in the last 3 weeks or with a counted sound.
create or replace view mart.tiktok_trending_sounds as
with kd as (
  select distinct on (spotify_track_id) spotify_track_id, rank, streams, streams_7d_change from staging.trend_spotify_ph_daily
  where snapshot_date = (select max(snapshot_date) from staging.trend_spotify_ph_daily) order by spotify_track_id, rank
), vh as (
  select distinct on (track_id) track_id, position from staging.spotify_playlist_track
  where playlist = 'Viral Hits Philippines'
    and snapshot_date = (select max(snapshot_date) from staging.spotify_playlist_track where playlist = 'Viral Hits Philippines')
  order by track_id, position
)
select rank() over (order by w.added_7d desc nulls last, w.videos desc nulls last) as trend_rank,
       w.song, w.artist, w.song_key, w.spotify_id, array_to_string(w.found_in, ', ') as found_in,
       w.added_7d as videos_added_7d, w.videos as tiktok_videos, w.sounds_kept, w.fan_sounds_kept,
       w.sounds_unchecked, w.sounds_with_gain, w.counted_on,
       ts.title || ' / ' || ts.author as top_sound, ts.link as top_sound_link,
       kd.rank as spotify_ph_rank, kd.streams as spotify_daily_streams, kd.streams_7d_change as spotify_7d_change,
       vh.position as viral_hits_pos,
       case when w.sounds_kept = 0 then 'Find its sounds: paste links in the sheet'
            when w.fan_sounds_kept = 0 then 'Only TikTok-credited sounds: paste top fan sounds'
            when w.sounds_unchecked > 0 then 'Caption check pending'
            when w.sounds_with_gain = 0 then 'First count: gain next week'
            else 'OK' end as to_do,
       w.first_seen, w.last_seen
from staging.tiktok_trend_song_week w
left join raw.tiktok_trend_song t using (song_key)
left join staging.tiktok_trend_sound ts on ts.song_key = w.song_key and ts.music_id = w.top_music_id
left join kd on kd.spotify_track_id = t.spotify_track_id
left join vh on vh.track_id = t.spotify_track_id
where w.last_seen >= current_date - 21 or w.sounds_with_gain > 0;

comment on view mart.tiktok_trending_sounds is
  'Trending OPM sounds this week: TikTok videos added in 7 days per song, official + fan sounds (sql/028).';

------------------------------------------------------------------ invite score (replaces sql/026's view)
-- Only change: the new song's TikTok part (tt_song_videos, 25%) ranks videos added in 7 days (artist sounds + tracked
-- trending sounds, whichever is bigger) once any weekly gain exists; before that, all-time videos as in sql/026.
-- The new song is now picked by weekly gain first. Tracked trending songs join the song list. New columns at the end.
create or replace view mart.invite_candidates as
with sp as (
  select distinct on (s.spotify_id) s.spotify_id, s.name as artist, s.artist_name_key, s.monthly_listeners,
         s.followers as spotify_followers, s.followers_per_listener, a.match_type
  from staging.spotify_artist_snapshot s
  join raw.spotify_artists a using (spotify_id)
  where s.snapshot_date > current_date - 14 and a.active
  order by s.spotify_id, s.snapshot_date desc
), city as (
  select c.spotify_id,
         sum(c.listeners) filter (where c.country = 'PH') as ph_listeners,
         sum(c.listeners) filter (where c.city in ('Quezon City', 'Manila', 'Makati City', 'Caloocan', 'Pasig', 'San Juan',
                                                   'Paranaque City', 'Baguio City')) as manila_baguio_listeners
  from staging.spotify_top_city c
  where c.snapshot_date = (select max(x.snapshot_date) from staging.spotify_top_city x where x.spotify_id = c.spotify_id)
  group by 1
), chart as (
  select a.spotify_id, min(t.rank) as best_chart_rank, max(t.weeks_on_chart) as weeks_on_chart,
         count(distinct t.spotify_track_id) as chart_songs
  from staging.trend_spotify_ph t
  cross join lateral unnest(t.spotify_artist_ids) as a(spotify_id)
  where t.snapshot_date >= current_date - 56
  group by 1
), viral as (
  select distinct unnest(artist_ids) as spotify_id from staging.spotify_playlist_track
  where snapshot_date = (select max(snapshot_date) from staging.spotify_playlist_track)
), tiktok as (
  select a.spotify_id, a.handle as tiktok_handle, a.found_by as tiktok_found_by, a.followers as tiktok_followers,
         g.growth_4w as tiktok_follower_growth_4w
  from staging.artist_tiktok_account a
  left join staging.tiktok_account_growth g using (handle)
), posts as (
  select va.spotify_id, va.platform, v.published_date_ph as d, v.vs_series_median, tv.perf_index
  from staging.video_artist va
  join mart.tableau_dim_video v on v.platform = va.platform and v.video_id = va.video_id
  left join mart.tableau_tiktok_video tv on va.platform = 'TikTok' and tv.video_id = va.video_id
), visit_marks as (
  select spotify_id, d, (lag(d) over (partition by spotify_id order by d) is null
                         or d - lag(d) over (partition by spotify_id order by d) > 60) as starts_visit
  from posts
), record as (
  select p.spotify_id,
         count(*) filter (where p.platform = 'YouTube')                                     as ndn_youtube_videos,
         count(*) filter (where p.platform = 'TikTok')                                      as ndn_tiktok_clips,
         percentile_cont(0.5) within group (order by p.perf_index)                          as ndn_tiktok_index,
         percentile_cont(0.5) within group (order by p.vs_series_median)
           filter (where p.platform = 'YouTube')                                            as ndn_youtube_index,
         max(p.d)                                                                           as last_ndn_post,
         (select max(m.d) from visit_marks m where m.spotify_id = p.spotify_id and m.starts_visit) as latest_visit
  from posts p
  group by p.spotify_id
), pool as (
  select sp.*, ps.ph_share
  from sp
  left join staging.spotify_artist_ph_share ps using (spotify_id)
  where sp.match_type not in ('ph_chart', 'viral_playlist')
     or exists (select 1 from record r where r.spotify_id = sp.spotify_id)
     or ps.ph_share >= 0.9
), kw as (
  -- every kworb song of the artist (one row per title key), rn = rank by Spotify daily streams
  select k.*, row_number() over (partition by k.spotify_id order by k.daily_streams desc nulls last) as rn
  from (select distinct on (ks.spotify_id, staging.title_key(ks.title)) ks.spotify_id, staging.title_key(ks.title) as title_key,
               ks.track_id, ks.title, ks.daily_streams, ks.total_streams
        from staging.kworb_song ks
        where ks.snapshot_date = (select max(x.snapshot_date) from staging.kworb_song x where x.spotify_id = ks.spotify_id)
          and ks.daily_streams >= 1000
        order by ks.spotify_id, staging.title_key(ks.title), ks.daily_streams desc) k
), ag as materialized (
  -- sql/028: videos added in 7 days over each artist song's own sounds. "materialized" = computed once; inlined, the
  -- planner re-ran the weekly-gain view per song and the view timed out.
  select a.spotify_id, a.title_key, sum(w.added_7d) as added_7d
  from staging.tiktok_artist_sound a join staging.tiktok_sound_week w using (music_id)
  where a.title_key <> '' group by 1, 2
), tr as materialized (
  select spotify_id, title_key, sum(videos) as videos, sum(added_7d) as added_7d
  from staging.tiktok_trend_song_week where spotify_id is not null and sounds_kept > 0 group by 1, 2
), songs as (
  -- top 5 Spotify songs + every TikTok catalog song (Spotify numbers for it even outside the top 5)
  select s.spotify_id, s.title_key,
         coalesce(k.title, t.title) as title, k.track_id, k.daily_streams, k.total_streams, k.rn,
         greatest(t.tiktok_videos, tr.videos) as tiktok_videos, t.tiktok_growth_4w, t.sound_created, t.music_ids,
         greatest(tr.added_7d, ag.added_7d)::bigint as tiktok_added_7d
  from (select spotify_id, title_key from kw where rn <= 5
        union
        select spotify_id, title_key from staging.tiktok_artist_song
        union  -- sql/028: tracked trending songs (official + fan sounds)
        select spotify_id, title_key from tr) s
  left join kw k on k.spotify_id = s.spotify_id and k.title_key = s.title_key
  left join staging.tiktok_artist_song t on t.spotify_id = s.spotify_id and t.title_key = s.title_key
  left join tr on tr.spotify_id = s.spotify_id and tr.title_key = s.title_key
  left join ag on ag.spotify_id = s.spotify_id and ag.title_key = s.title_key
), song_status as (
  -- with "already on NDN YouTube" and release date
  select s.*,
         (p.tkey is not null or (s.track_id is not null and pi.track_id is not null)) as on_ndn,
         coalesce(rel.first_release, s.sound_created) as released
  from songs s
  left join (select distinct va.spotify_id, staging.title_key(v.song) as tkey
             from staging.video_artist va
             join mart.tableau_dim_video v on v.platform = va.platform and v.video_id = va.video_id
             where va.platform = 'YouTube' and v.song is not null) p on p.spotify_id = s.spotify_id and p.tkey = s.title_key
  left join (select distinct spotify_id, studio_track_id as track_id from staging.youtube_session_spotify
             where studio_track_id is not null) pi on pi.spotify_id = s.spotify_id and pi.track_id = s.track_id
  left join staging.spotify_artist sa on sa.spotify_id = s.spotify_id
  left join (select staging.name_key(artist) as akey, title_key, min(first_release) as first_release
             from staging.music_catalog_status group by 1, 2) rel on rel.akey = sa.artist_name_key and rel.title_key = s.title_key
), hit as (
  -- Vic 2026-10-22: the point of an invite is a live clip of the song people are using and streaming NOW.
  select distinct on (s.spotify_id) s.spotify_id, s.title as new_hit, s.daily_streams as new_hit_daily_streams,
         s.released as new_hit_released, s.tiktok_videos as new_hit_tiktok_videos,
         s.tiktok_growth_4w as new_hit_tiktok_growth_4w, s.tiktok_added_7d as new_hit_tiktok_added_7d,
         case when s.tiktok_videos is not null and s.daily_streams is not null then 'TikTok + Spotify'
              when s.tiktok_videos is not null then 'TikTok' else 'Spotify' end as new_hit_found_on
  from song_status s
  left join record r using (spotify_id)
  where not s.on_ndn
    and (s.released > coalesce(r.latest_visit, current_date - 365)
         or (s.released is null and s.total_streams < 365 * s.daily_streams))
  order by s.spotify_id, s.tiktok_added_7d desc nulls last, s.tiktok_videos desc nulls last, s.daily_streams desc nulls last
), top_song as (
  select spotify_id, title as top_song, daily_streams as top_song_daily_streams, on_ndn as top_song_on_ndn
  from song_status where rn = 1
), top_tiktok as (
  select distinct on (spotify_id) spotify_id, title as top_tiktok_song, tiktok_videos as top_tiktok_song_videos,
         on_ndn as top_tiktok_song_on_ndn
  from song_status where tiktok_videos is not null
  order by spotify_id, tiktok_videos desc
), base as (
  select p.*, city.ph_listeners, city.manila_baguio_listeners, chart.best_chart_rank, chart.weeks_on_chart,
         chart.chart_songs, (viral.spotify_id is not null) as on_viral_hits,
         tiktok.tiktok_handle, tiktok.tiktok_found_by, tiktok.tiktok_followers, tiktok.tiktok_follower_growth_4w,
         f.fans as fans_asking, f.fans_per_1000_comments, f.tiktok_asks,
         r.ndn_youtube_videos, r.ndn_tiktok_clips, r.ndn_tiktok_index, r.ndn_youtube_index, r.last_ndn_post,
         r.latest_visit, hit.new_hit, hit.new_hit_daily_streams, hit.new_hit_released, hit.new_hit_tiktok_videos,
         hit.new_hit_tiktok_growth_4w, hit.new_hit_found_on, hit.new_hit_tiktok_added_7d,
         ts.top_song, ts.top_song_daily_streams, ts.top_song_on_ndn,
         tt.top_tiktok_song, tt.top_tiktok_song_videos,
         case when ts.top_song is null and tt.top_tiktok_song is null then 'No song data'
              when hit.new_hit is not null then 'New hit not on NDN'
              when coalesce(ts.top_song_on_ndn, false) or coalesce(tt.top_tiktok_song_on_ndn, false) then 'Hit already on NDN'
              else 'No new hit since last visit' end                               as hit_status,
         coalesce(city.manila_baguio_listeners, 0)
           + 0.5 * (coalesce(city.ph_listeners, 0) - coalesce(city.manila_baguio_listeners, 0)) as local_raw
  from pool p
  left join city using (spotify_id)
  left join chart using (spotify_id)
  left join viral using (spotify_id)
  left join tiktok using (spotify_id)
  left join mart.fan_demand_artist f using (spotify_id)
  left join record r using (spotify_id)
  left join hit using (spotify_id)
  left join top_song ts using (spotify_id)
  left join top_tiktok tt using (spotify_id)
), parts as (
  select b.*,
         -- sql/028: videos added in 7 days once weekly counts exist; all-time videos before that
         case when count(new_hit_tiktok_added_7d) over () > 0 then
                case when new_hit_tiktok_added_7d is null then 0 else round(100 * percent_rank() over (
                  partition by new_hit_tiktok_added_7d is null order by new_hit_tiktok_added_7d))::int end
              when new_hit_tiktok_videos is null then 0 else round(100 * percent_rank() over (
           partition by new_hit_tiktok_videos is null order by new_hit_tiktok_videos))::int end         as tt_song_videos,
         case when count(new_hit_tiktok_added_7d) over () > 0 then 'videos added in 7 days'
              else 'all-time videos (no weekly count yet)' end                                      as tt_song_basis,
         case when new_hit_tiktok_growth_4w is null then 0 else round(100 * percent_rank() over (
           partition by new_hit_tiktok_growth_4w is null order by new_hit_tiktok_growth_4w))::int end   as tt_song_growth,
         case when tiktok_follower_growth_4w is null then 0 else round(100 * percent_rank() over (
           partition by tiktok_follower_growth_4w is null order by tiktok_follower_growth_4w))::int end as tt_follower_growth,
         case when latest_visit is null or ndn_tiktok_index is null then 50 else round(100 * percent_rank() over (
           partition by latest_visit is null or ndn_tiktok_index is null order by ndn_tiktok_index))::int end as track_record,
         case when new_hit_daily_streams is null then 0 else round(100 * percent_rank() over (
           partition by new_hit_daily_streams is null order by new_hit_daily_streams))::int end         as new_hit_hype,
         round(100 * percent_rank() over (order by coalesce(201 - best_chart_rank, 0)))::int    as momentum,
         round(100 * percent_rank() over (order by local_raw))::int                             as local_reach,
         round(100 * percent_rank() over (order by coalesce(fans_per_1000_comments, 0)))::int   as fan_demand,
         round(100 * percent_rank() over (order by coalesce(monthly_listeners, 0)))::int        as size,
         round(100 * percent_rank() over (order by coalesce(followers_per_listener, 0)))::int   as loyalty
  from base b
), scored as (
  select p.*,
         round(0.25 * tt_song_videos + 0.15 * tt_song_growth + 0.10 * tt_follower_growth + 0.05 * track_record
               + 0.15 * new_hit_hype + 0.10 * momentum + 0.05 * local_reach
               + 0.10 * fan_demand + 0.05 * size, 1)                                            as score,
         round(0.25 * tt_song_videos + 0.15 * tt_song_growth + 0.10 * tt_follower_growth + 0.05 * track_record, 1) as tiktok_points,
         round(0.15 * new_hit_hype + 0.10 * momentum + 0.05 * local_reach, 1)                    as spotify_points,
         round(0.10 * fan_demand + 0.05 * size, 1)                                               as other_points,
         (latest_visit + interval '10 months')::date                                            as cooldown_until
  from parts p
), final as (
  select s.*,
         case when s.cooldown_until > current_date then 'Cooling down'
              when s.hit_status = 'New hit not on NDN' then 'Recommend'
              else 'Not now' end                                                     as status
  from scored s
)
select s.spotify_id, s.artist, s.status, s.hit_status,
       case when s.latest_visit is null then 'New to NDN' else 'Played for NDN' end      as ndn_history,
       rank() over (partition by s.status order by s.score desc)                       as status_rank,
       s.new_hit, s.new_hit_daily_streams, s.new_hit_released, s.top_song, s.top_song_daily_streams,
       s.top_song_on_ndn,
       s.score, s.new_hit_hype, s.momentum, s.local_reach, s.fan_demand, s.track_record, s.size, s.loyalty,
       s.monthly_listeners, s.spotify_followers, s.followers_per_listener, s.ph_listeners, s.manila_baguio_listeners,
       s.best_chart_rank, s.weeks_on_chart, s.chart_songs, s.tiktok_handle, s.tiktok_followers,
       s.fans_asking, s.fans_per_1000_comments, s.tiktok_asks, s.ndn_youtube_videos, s.ndn_tiktok_clips,
       round(s.ndn_tiktok_index::numeric, 2) as ndn_tiktok_index, round(s.ndn_youtube_index::numeric, 2) as ndn_youtube_index,
       s.latest_visit, s.last_ndn_post, s.cooldown_until,
       -- new in sql/026
       case s.match_type when 'ph_chart' then 'PH weekly chart' when 'viral_playlist' then 'Viral Hits PH'
            else 'NDN artist or Vic''s list' end                                        as found_via,
       s.new_hit_found_on, s.new_hit_tiktok_videos, round(s.new_hit_tiktok_growth_4w, 3) as new_hit_tiktok_growth_4w,
       s.top_tiktok_song, s.top_tiktok_song_videos,
       s.tiktok_points, s.spotify_points, s.other_points, s.tt_song_videos, s.tt_song_growth, s.tt_follower_growth,
       round(s.ph_share, 2) as ph_share, s.on_viral_hits, s.tiktok_found_by,
       round(s.tiktok_follower_growth_4w, 3) as tiktok_follower_growth_4w,
       -- new in sql/028
       s.new_hit_tiktok_added_7d, s.tt_song_basis
from final s;

comment on view mart.invite_candidates is
  'Top-10-to-invite score, TikTok first (INVITE_SCORE.md), tt_song_videos = TikTok videos added in 7 days (sql/028).';
