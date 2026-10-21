-- 026: TikTok-first invite score (INVITE_SCORE.md 'TikTok-first plan', Vic 2026-10-22).
-- Independent analysis of public data, not affiliated with Nine Degrees North.
--   1. raw.tiktok_artist_video: each artist account's latest 30 videos with their sound
--      (extract_tiktok_extras.py --steps artist_videos, yt-dlp account listing; GitHub weekly.yml job tiktok-artists).
--      Artists post their own songs, so this finds each song's official TikTok sound. Only catalog sounds credited
--      to the artist count, which drops AI/meme/"original sound" audio.
--   2. Those sounds join the weekly sound counts (step artist_sounds -> raw.tiktok_sound_stats, as in sql/014).
--   3. Artists without a known TikTok account: their Instagram username (Spotify links, sql/024) is tried as the
--      TikTok handle and kept only when the display name contains the artist's name, or the handle does and the
--      account posts the artist's released songs.
--   4. raw.spotify_playlist_snapshot: Spotify's own "Viral Hits Philippines" playlist, weekly (extract_spotify.py
--      --steps playlists). Spotify's "Viral 50 - Philippines" chart playlist does not come up in Spotify search
--      (checked 2026-10-22), so this editorial playlist stands in. It only adds candidates; it is not a score part.
--      Its artists and the PH weekly chart artists join the candidate pool; non-OPM ones are left out (PH share).
--   5. mart.invite_candidates rebuilt with the TikTok-first weights.

------------------------------------------------------------------ raw
create table if not exists raw.tiktok_artist_video (
  handle     text not null,
  video_id   text not null,
  fetched_at timestamptz not null default now(),
  posted_at  timestamptz,
  views      bigint,
  music      jsonb,                   -- id, title, authorName, original, album, duration
  primary key (handle, video_id)
);

create table if not exists raw.tiktok_artist_video_fetch (
  handle     text primary key,
  fetched_at timestamptz not null default now(),
  guess_for  text,                    -- spotify_id when the handle is a guess from the artist's Instagram username
  found      boolean not null,
  nickname   text,                    -- the account's display name
  videos     int
);

create table if not exists raw.spotify_playlists (
  playlist_id text primary key,
  name        text not null,
  active      boolean not null default true,
  note        text
);

create table if not exists raw.spotify_playlist_snapshot (
  playlist_id   text not null,
  snapshot_date date not null,
  fetched_at    timestamptz not null default now(),
  payload       jsonb not null,       -- {name, description, total, tracks: [{pos, track_id, name, artists [{id, name}], added_at}]}
  primary key (playlist_id, snapshot_date)
);

alter table raw.tiktok_artist_video enable row level security;
alter table raw.tiktok_artist_video_fetch enable row level security;
alter table raw.spotify_playlists enable row level security;
alter table raw.spotify_playlist_snapshot enable row level security;

insert into raw.spotify_playlists (playlist_id, name, note) values
  ('37i9dQZF1DXe3Jzj3uus9u', 'Viral Hits Philippines', 'Spotify editorial "Viral sa Pinas!", ~100 songs; found by search 2026-10-22')
on conflict do nothing;

------------------------------------------------------------------ staging
-- TikTok ids start with their creation time (seconds, top 32 bits). For a catalog sound that is when the label
-- uploaded the song, about 2 weeks before release (3 Rob Deniel songs vs Deezer), so it is never late.
create or replace function staging.tiktok_id_date(id text) returns date language sql immutable as
$$ select case when id ~ '^\d{15,20}$' then to_timestamp(floor(id::numeric / 4294967296))::date end $$;

create or replace view staging.spotify_playlist_track as
select s.playlist_id, p.name as playlist, s.snapshot_date,
       (t->>'pos')::int                                                   as position,
       t->>'track_id'                                                     as track_id,
       t->>'name'                                                         as song,
       array(select a->>'id' from jsonb_array_elements(t->'artists') a)   as artist_ids,
       array(select a->>'name' from jsonb_array_elements(t->'artists') a) as artists,
       (t->>'added_at')::timestamptz                                      as added_at
from raw.spotify_playlist_snapshot s
join raw.spotify_playlists p using (playlist_id)
cross join lateral jsonb_array_elements(s.payload->'tracks') t;

-- Share of the artist's top-5-city listeners who are in the Philippines (latest artist snapshot): the OPM check
-- for chart and playlist artists who never played for NDN.
create or replace view staging.spotify_artist_ph_share as
select distinct on (spotify_id) spotify_id, snapshot_date,
       coalesce(sum(listeners) filter (where country = 'PH'), 0)::numeric / nullif(sum(listeners), 0) as ph_share
from staging.spotify_top_city
group by spotify_id, snapshot_date
order by spotify_id, snapshot_date desc;

-- One TikTok account per Spotify artist: listed by Vic > tagged in NDN captions > Instagram name (checked).
-- Several handles for one artist: the one with the most followers.
create or replace view staging.artist_tiktok_account as
with sa as (
  select spotify_id, name, artist_name_key, tiktok_handle, staging.name_key(name) as nkey
  from raw.spotify_artists where active
), c as (
  select spotify_id, tiktok_handle as handle, 1 as pri, 'listed by Vic' as found_by from sa where tiktok_handle is not null
  union all
  select sa.spotify_id, t.handle, 1, 'listed by Vic'
  from sa join raw.tiktok_accounts t on t.role = 'artist' and t.active and t.artist_name_key = sa.artist_name_key
  union all
  select sa.spotify_id, c.handle, 2, 'tagged in NDN captions'
  from sa join staging.tiktok_artist_account_candidate c on c.artist_name_key = sa.artist_name_key
  where not exists (select 1 from raw.tiktok_accounts t where t.handle = c.handle and not t.active)
  union all
  select sa.spotify_id, f.handle, 3, 'Instagram name, checked'
  from sa join raw.tiktok_artist_video_fetch f on f.guess_for = sa.spotify_id
  where f.found and length(sa.nkey) >= 3
    -- display name has the artist's name, or (short display names like "Ica" for Ica Frias) the handle has it AND
    -- the account posts released songs credited to the artist; a fan account rarely has both
    and (staging.name_key(f.nickname) like '%' || sa.nkey || '%'
         or (length(sa.nkey) >= 4 and staging.name_key(f.handle) like '%' || sa.nkey || '%'
             and exists (select 1 from raw.tiktok_artist_video v
                         where v.handle = f.handle and not coalesce((v.music->>'original')::boolean, true)
                           and staging.name_key(v.music->>'authorName') like '%' || sa.nkey || '%')))
), fol as (
  select distinct on (handle) handle, followers from staging.tiktok_account_snapshot_other
  order by handle, snapshot_date desc
)
select distinct on (c.spotify_id) c.spotify_id, c.handle, c.found_by, fol.followers
from c left join fol using (handle)
order by c.spotify_id, c.pri, fol.followers desc nulls last, c.handle;

-- The artist's own catalog sounds (not "original sound", credited to the artist) in their latest videos.
create or replace view staging.tiktok_artist_sound as
select a.spotify_id, a.handle, v.music->>'id' as music_id,
       min(v.music->>'title')                       as sound_title,
       min(v.music->>'album')                       as album,
       staging.title_key(min(v.music->>'title'))    as title_key,
       staging.tiktok_id_date(v.music->>'id')       as sound_created,
       count(*)                                     as own_videos,
       sum(v.views)                                 as own_views,
       max(v.posted_at)                             as last_own_post
from staging.artist_tiktok_account a
join raw.spotify_artists sa using (spotify_id)
join raw.tiktok_artist_video v on v.handle = a.handle
where not coalesce((v.music->>'original')::boolean, true)
  and length(staging.name_key(sa.name)) >= 3
  and staging.name_key(v.music->>'authorName') like '%' || staging.name_key(sa.name) || '%'
group by a.spotify_id, a.handle, v.music->>'id';

-- Videos using each sound now vs about 4 weeks earlier (nearest snapshot at least 6 days back),
-- growth scaled to 4 weeks so a 1-week and a 4-week gap compare.
create or replace view staging.tiktok_sound_growth as
with s as (
  select music_id, snapshot_date, videos_using_sound as v from staging.tiktok_sound_stats where videos_using_sound is not null
), l as (
  select distinct on (music_id) music_id, snapshot_date as d, v from s order by music_id, snapshot_date desc
)
select l.music_id, l.d as snapshot_date, l.v as videos, p.d as then_date, p.v as videos_then, l.d - p.d as days,
       case when p.v > 0 then power(l.v::numeric / p.v, 28.0 / (l.d - p.d)) - 1 end as growth_4w
from l
left join lateral (select s.snapshot_date as d, s.v from s
                   where s.music_id = l.music_id and s.snapshot_date <= l.d - 6
                   order by abs((l.d - 28) - s.snapshot_date), s.snapshot_date limit 1) p on true;

-- Per artist song (sped-up etc. versions share a title key): TikTok videos summed over its sounds,
-- growth of its biggest sound.
create or replace view staging.tiktok_artist_song as
select s.spotify_id, s.title_key,
       (array_agg(s.sound_title order by g.videos desc nulls last))[1] as title,
       array_agg(s.music_id order by g.videos desc nulls last)         as music_ids,
       min(s.sound_created)                                            as sound_created,
       sum(s.own_videos)                                               as own_videos,
       sum(g.videos)                                                   as tiktok_videos,
       (array_agg(g.growth_4w order by g.videos desc nulls last))[1]   as tiktok_growth_4w,
       max(g.snapshot_date)                                            as counted_on
from staging.tiktok_artist_sound s
left join staging.tiktok_sound_growth g using (music_id)
where s.title_key <> ''
group by s.spotify_id, s.title_key;

-- TikTok followers now vs about 4 weeks earlier, scaled to 4 weeks (same rule as sounds).
create or replace view staging.tiktok_account_growth as
with s as (
  select handle, snapshot_date, followers from staging.tiktok_account_snapshot_other where followers is not null
), l as (
  select distinct on (handle) handle, snapshot_date as d, followers from s order by handle, snapshot_date desc
)
select l.handle, l.d as snapshot_date, l.followers, p.followers as followers_then, l.d - p.d as days,
       case when p.followers > 0 then power(l.followers::numeric / p.followers, 28.0 / (l.d - p.d)) - 1 end as growth_4w
from l
left join lateral (select s.snapshot_date as d, s.followers from s
                   where s.handle = l.handle and s.snapshot_date <= l.d - 6
                   order by abs((l.d - 28) - s.snapshot_date), s.snapshot_date limit 1) p on true;

------------------------------------------------------------------ mart
-- Replaces sql/025's view. Pool: every active Spotify artist (NDN performers, Vic's TikTok list, PH weekly chart,
-- Viral Hits PH); chart/playlist artists who never played for NDN need >= 90% PH listeners in their top 5 cities
-- (258 of 272 NDN artists are at 90%+; at 50% Boyz II Men and Leona Lewis got in). A few non-OPM acts still pass
-- (Nick Jonas, Edwin McCain, Stephen Speaks, and a label, groundZERO Records): Vic switches them off by setting
-- raw.spotify_artists.active = false.
-- Gate unchanged: a NEW song (released after the latest NDN visit, or in the last 12 months for new artists) that is
-- not on NDN's YouTube. New songs come from two places now: the artist's TikTok catalog sounds and their top 5
-- Spotify songs (kworb); the one with the most TikTok videos wins, then Spotify daily streams.
-- Release date: Deezer catalog, else the TikTok sound's creation date, else kworb total/daily streams < 365.
-- Weights (TikTok 55, Spotify 30, other 15), each part a percentile 0-100 in the pool; no data = 0:
--   TikTok:  new song's TikTok videos 25, their 4-week growth 15, artist TikTok follower growth 10,
--            NDN TikTok track record 5 (never played = 50)
--   Spotify: new song's daily streams 15, PH weekly chart momentum 10, local reach (Manila + Baguio) 5
--   Other:   fan requests 10, size (monthly listeners) 5
-- Growth parts stay 0 for everyone until there are two weekly counts at least 6 days apart.
-- sql/025's 40 columns keep their names and order (so "create or replace" works); new columns follow. Two old
-- names now mean: new_hit_hype = the new song's Spotify daily streams part (15), track_record = NDN TikTok record
-- (5). loyalty is still shown but no longer weighted.
-- Each artist's own latest Spotify / kworb snapshot (last 14 days): new candidates are read on other days than the
-- weekly run, so "the latest date overall" would drop everyone else (sql/025 assumed one date for all).
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
), songs as (
  -- top 5 Spotify songs + every TikTok catalog song (Spotify numbers for it even outside the top 5)
  select s.spotify_id, s.title_key,
         coalesce(k.title, t.title) as title, k.track_id, k.daily_streams, k.total_streams, k.rn,
         t.tiktok_videos, t.tiktok_growth_4w, t.sound_created, t.music_ids
  from (select spotify_id, title_key from kw where rn <= 5
        union
        select spotify_id, title_key from staging.tiktok_artist_song) s
  left join kw k on k.spotify_id = s.spotify_id and k.title_key = s.title_key
  left join staging.tiktok_artist_song t on t.spotify_id = s.spotify_id and t.title_key = s.title_key
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
         s.tiktok_growth_4w as new_hit_tiktok_growth_4w,
         case when s.tiktok_videos is not null and s.daily_streams is not null then 'TikTok + Spotify'
              when s.tiktok_videos is not null then 'TikTok' else 'Spotify' end as new_hit_found_on
  from song_status s
  left join record r using (spotify_id)
  where not s.on_ndn
    and (s.released > coalesce(r.latest_visit, current_date - 365)
         or (s.released is null and s.total_streams < 365 * s.daily_streams))
  order by s.spotify_id, s.tiktok_videos desc nulls last, s.daily_streams desc nulls last
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
         hit.new_hit_tiktok_growth_4w, hit.new_hit_found_on,
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
         case when new_hit_tiktok_videos is null then 0 else round(100 * percent_rank() over (
           partition by new_hit_tiktok_videos is null order by new_hit_tiktok_videos))::int end         as tt_song_videos,
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
       round(s.tiktok_follower_growth_4w, 3) as tiktok_follower_growth_4w
from final s;

comment on view mart.invite_candidates is
  'Top-10-to-invite score, TikTok first (INVITE_SCORE.md TikTok-first plan, percentile parts 0-100) plus the raw numbers behind it. sql/026.';
