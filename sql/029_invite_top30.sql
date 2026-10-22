-- 029: invite score v3 (Vic 2026-10-23): the songs come from three Spotify playlists only, and TikTok numbers come from
-- searching each song's title on TikTok every 3 days. Backup of v2: backup/invite_v2_2026-10-23/ (local).
-- 1. Lists (spotify.yml playlists step, weekly; raw.spotify_playlists): Top 50 - Philippines (Spotify, 37i9dQZEVXbNBz9cRCSFkY),
--    Viral Hits Philippines (Spotify), Billboard Philippines Hot 100 (fan-made weekly copy, 6r5KcNnlzOxlLYsbspfEMA).
--    Points per list: Top 50 #1 = 100 ... #50 = 2 ((51 - pos) * 2); Viral Hits / Billboard #1 = 100 ... #100 = 1 (101 - pos).
--    A song's points = the sum over the lists; OPM = main artist in staging.opm_artist (90%+ PH listeners, or Vic's pool).
--    The 30 OPM songs with the most points are the invite songs.
-- 2. TikTok: the home server's top30_tiktok.py (cron every 3 days, logged-in dummy account; Vic chose this knowing
--    tiktok.com's robots.txt disallows /search) searches each title in TikTok's Sounds tab, keeps the song's sounds
--    (official + versions; caption vote for the ones not credited to the artist) and saves every sound's video count.
--    Through the Edge Function tiktok-trending (step=top30 / step=search).
-- 3. Score: weights unchanged (TikTok 55, Spotify 30, other 15). Pool = the artists of the 30 songs; the new song = their
--    top-30 song (not on NDN's YouTube, out since their last visit). tt_song_videos (25) = all TikTok videos using the
--    song's counted sounds (Vic: total videos); tt_song_growth (15) = 4-week growth of those videos.

create or replace view staging.invite_top30 as
with lists as (
  select t.playlist, t.position, t.song, t.track_id, t.artist_ids[1] as spotify_id, t.artists[1] as artist,
         case t.playlist when 'Top 50 - Philippines' then (51 - t.position) * 2 else greatest(101 - t.position, 0) end as points
  from staging.spotify_playlist_track t
  where t.playlist in ('Top 50 - Philippines', 'Viral Hits Philippines', 'Billboard Philippines Hot 100')
    and t.snapshot_date = (select max(x.snapshot_date) from staging.spotify_playlist_track x where x.playlist = t.playlist)
), s as (
  select l.spotify_id, staging.title_key(l.song) as title_key, min(l.song) as song, min(l.artist) as artist,
         min(l.track_id) as track_id, sum(l.points) as points,
         min(l.position) filter (where l.playlist = 'Top 50 - Philippines')          as top50_pos,
         min(l.position) filter (where l.playlist = 'Viral Hits Philippines')        as viral_pos,
         min(l.position) filter (where l.playlist = 'Billboard Philippines Hot 100') as billboard_pos
  from lists l
  where l.spotify_id in (select spotify_id from staging.opm_artist) and staging.title_key(l.song) <> ''
  group by 1, 2
)
select r.* from (
  select row_number() over (order by points desc, coalesce(top50_pos, 999), coalesce(billboard_pos, 999)) as rank,
         staging.name_key(artist) || '|' || title_key as song_key, s.*
  from s) r
where r.rank <= 30;

-- The weekly/3-day refresh (mart.weekly_tiktok_trending) now adds the top 30 to the tracked songs (sql/028's kworb /
-- new-release / hashtag candidates are retired; songs already tracked stay).
create or replace view staging.tiktok_trend_candidate as
select song_key, song, artist, spotify_id, track_id as spotify_track_id,
       array_remove(array[case when top50_pos is not null then 'top50' end,
                          case when viral_pos is not null then 'viral_hits' end,
                          case when billboard_pos is not null then 'billboard' end], null) as found_in
from staging.invite_top30;

-- Per tracked song: 4-week growth of its counted sounds, weighted by each sound's earlier count.
create or replace view staging.tiktok_trend_song_growth as
select s.song_key, sum(g.growth_4w * g.videos_then) / nullif(sum(g.videos_then), 0) as growth_4w
from staging.tiktok_trend_sound s
join staging.tiktok_sound_growth g using (music_id)
where s.status = 'kept' and g.videos_then > 0
group by s.song_key;

-- Power BI "OPM top 30 on TikTok": the 30 songs, their list places and TikTok numbers.
create or replace view mart.invite_top30_tiktok as
select t.rank, t.song, t.artist, t.song_key, t.spotify_id, t.points, t.top50_pos, t.viral_pos, t.billboard_pos,
       w.videos as tiktok_videos, w.added_7d as videos_added_7d, round(g.growth_4w, 3) as growth_4w,
       w.sounds_kept, w.fan_sounds_kept, w.sounds_unchecked, w.counted_on,
       ts.title || ' / ' || ts.author as top_sound, ts.link as top_sound_link,
       case when w.song_key is null or w.sounds_kept = 0 then 'Waiting for the TikTok search (every 3 days)'
            when w.sounds_unchecked > 0 then 'Caption check pending'
            when g.growth_4w is null then 'Growth after a second count 6+ days later'
            else 'OK' end as to_do
from staging.invite_top30 t
left join staging.tiktok_trend_song_week w using (song_key)
left join staging.tiktok_trend_song_growth g using (song_key)
left join staging.tiktok_trend_sound ts on ts.song_key = t.song_key and ts.music_id = w.top_music_id;

comment on view mart.invite_top30_tiktok is
  'OPM top 30 of Top 50 PH + Viral Hits PH + Billboard PH Hot 100, with TikTok videos per song (sql/029).';

------------------------------------------------------------------ invite score v3 (replaces sql/028's view)
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
  where playlist = 'Viral Hits Philippines'
    and snapshot_date = (select max(snapshot_date) from staging.spotify_playlist_track where playlist = 'Viral Hits Philippines')
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
  where sp.spotify_id in (select spotify_id from staging.invite_top30)   -- sql/029: artists of the OPM top 30
), kw as (
  -- every kworb song of the artist (one row per title key), rn = rank by Spotify daily streams
  select k.*, row_number() over (partition by k.spotify_id order by k.daily_streams desc nulls last) as rn
  from (select distinct on (ks.spotify_id, staging.title_key(ks.title)) ks.spotify_id, staging.title_key(ks.title) as title_key,
               ks.track_id, ks.title, ks.daily_streams, ks.total_streams
        from staging.kworb_song ks
        where ks.snapshot_date = (select max(x.snapshot_date) from staging.kworb_song x where x.spotify_id = ks.spotify_id)
          and ks.daily_streams >= 1000
        order by ks.spotify_id, staging.title_key(ks.title), ks.daily_streams desc) k
), t30 as materialized (
  -- sql/029: the invite songs = the OPM top 30, with TikTok numbers from the 3-day title search
  select t.spotify_id, t.title_key, t.song, t.rank as top30_rank, t.points as top30_points, t.top50_pos, t.viral_pos,
         t.billboard_pos, w.videos, w.added_7d, g.growth_4w, sc.sound_created
  from staging.invite_top30 t
  left join staging.tiktok_trend_song_week w using (song_key)
  left join staging.tiktok_trend_song_growth g using (song_key)
  left join (select song_key, min(staging.tiktok_id_date(music_id)) as sound_created   -- release-date fallback
             from staging.tiktok_trend_sound where status = 'kept' group by 1) sc using (song_key)
), songs as (
  -- the top-30 songs (the only ones that can be the new song) + each artist's top Spotify song (for "Top song")
  select s.spotify_id, s.title_key,
         coalesce(k.title, t.song) as title, k.track_id, k.daily_streams, k.total_streams, k.rn,
         t.videos as tiktok_videos, t.growth_4w as tiktok_growth_4w, t.sound_created, null::text[] as music_ids,
         t.added_7d::bigint as tiktok_added_7d,
         t.top30_rank, t.top30_points, t.top50_pos, t.viral_pos, t.billboard_pos
  from (select spotify_id, title_key from t30 union select spotify_id, title_key from kw where rn = 1) s
  left join kw k on k.spotify_id = s.spotify_id and k.title_key = s.title_key
  left join t30 t on t.spotify_id = s.spotify_id and t.title_key = s.title_key
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
         s.top30_rank as new_hit_top30_rank, s.top30_points as new_hit_top30_points, s.top50_pos as new_hit_top50_pos,
         s.viral_pos as new_hit_viral_pos, s.billboard_pos as new_hit_billboard_pos,
         case when s.tiktok_videos is not null and s.daily_streams is not null then 'TikTok + Spotify'
              when s.tiktok_videos is not null then 'TikTok' else 'Spotify' end as new_hit_found_on
  from song_status s
  left join record r using (spotify_id)
  where not s.on_ndn and s.top30_rank is not null
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
         hit.new_hit_tiktok_growth_4w, hit.new_hit_found_on, hit.new_hit_tiktok_added_7d,
         hit.new_hit_top30_rank, hit.new_hit_top30_points, hit.new_hit_top50_pos, hit.new_hit_viral_pos,
         hit.new_hit_billboard_pos,
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
         -- sql/029 (Vic): all TikTok videos using the new song's counted sounds
         case when new_hit_tiktok_videos is null then 0 else round(100 * percent_rank() over (
           partition by new_hit_tiktok_videos is null order by new_hit_tiktok_videos))::int end         as tt_song_videos,
         'all TikTok videos so far'::text                                                           as tt_song_basis,
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
       s.new_hit_tiktok_added_7d, s.tt_song_basis,
       -- new in sql/029
       s.new_hit_top30_rank, s.new_hit_top30_points, s.new_hit_top50_pos, s.new_hit_viral_pos, s.new_hit_billboard_pos
from final s;

comment on view mart.invite_candidates is
  'Who to invite v3: artists of the OPM top 30 (Top 50 PH + Viral Hits PH + Billboard PH Hot 100), TikTok 55 / Spotify 30 / other 15 (sql/029).';
