-- 025: "Top 10 to invite" score (INVITE_SCORE.md), one row per candidate artist, with the raw numbers behind it.
-- Independent analysis of public data, not affiliated with Nine Degrees North.
--
-- Candidates: every artist with a Spotify artist page in raw.spotify_artists (NDN performers + PH chart artists).
-- Each part is a percentile rank 0-100 inside this pool, then weighted:
--   new-hit hype 25 (Spotify daily streams of the new hit, 0 without one; Vic 2026-10-22)
--   momentum 20 (best Spotify PH weekly rank, last 8 weeks; listener growth joins after 8 weeks of snapshots)
--   local reach 15 (Spotify top-city listeners: Metro Manila + Baguio count fully, other PH cities half)
--   fan demand 10 (distinct fans asking NDN per 1,000 comments, mart.fan_demand_artist)
--   track record 10 (median NDN TikTok index + YouTube vs-series-median, as percentiles; never played = 50)
--   size 10 (Spotify monthly listeners)   loyalty 10 (Spotify followers / monthly listeners)
-- Cooldown: no recommendation until 10 months after the artist's latest NDN visit (posts > 60 days apart = new visit).
-- New-hit gate (Vic 2026-10-22): recommended only when a top-5 song by Spotify daily streams is not on NDN's
-- YouTube yet and came out after the latest visit. Otherwise status = 'Not now', whatever the score.

create or replace view mart.invite_candidates as
with sp as (
  select spotify_id, name as artist, artist_name_key, monthly_listeners, followers as spotify_followers,
         followers_per_listener
  from staging.spotify_artist_snapshot
  where snapshot_date = (select max(snapshot_date) from staging.spotify_artist_snapshot)
), city as (
  select spotify_id,
         sum(listeners) filter (where country = 'PH') as ph_listeners,
         sum(listeners) filter (where city in ('Quezon City', 'Manila', 'Makati City', 'Caloocan', 'Pasig', 'San Juan',
                                               'Paranaque City', 'Baguio City')) as manila_baguio_listeners
  from staging.spotify_top_city
  where snapshot_date = (select max(snapshot_date) from staging.spotify_top_city)
  group by 1
), chart as (
  select a.spotify_id, min(t.rank) as best_chart_rank, max(t.weeks_on_chart) as weeks_on_chart,
         count(distinct t.spotify_track_id) as chart_songs
  from staging.trend_spotify_ph t
  cross join lateral unnest(t.spotify_artist_ids) as a(spotify_id)
  where t.snapshot_date >= current_date - 56
  group by 1
), tiktok as (
  select distinct on (artist_name_key) artist_name_key, handle as tiktok_handle, followers as tiktok_followers
  from staging.tiktok_account_snapshot_other
  where role = 'artist'
  order by artist_name_key, snapshot_date desc
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
), songs as (
  -- the artist's songs by Spotify daily streams (kworb), top 5 only, with "already on NDN YouTube" and release date
  select k.spotify_id, k.track_id, k.title, k.daily_streams, k.total_streams, k.rn,
         (p.tkey is not null or pi.track_id is not null) as on_ndn,
         rel.first_release
  from (select ks.*, lower(regexp_replace(regexp_replace(ks.title, '\s*[\(\[].*$', ''), '[^[:alnum:]]', '', 'g')) as tkey,
               row_number() over (partition by ks.spotify_id order by ks.daily_streams desc nulls last) as rn
        from staging.kworb_song ks
        where ks.snapshot_date = (select max(snapshot_date) from staging.kworb_song) and ks.daily_streams >= 1000) k
  left join (select distinct va.spotify_id,
                    lower(regexp_replace(regexp_replace(v.song, '\s*[\(\[].*$', ''), '[^[:alnum:]]', '', 'g')) as tkey
             from staging.video_artist va
             join mart.tableau_dim_video v on v.platform = va.platform and v.video_id = va.video_id
             where va.platform = 'YouTube' and v.song is not null) p on p.spotify_id = k.spotify_id and p.tkey = k.tkey
  left join (select distinct spotify_id, studio_track_id as track_id from staging.youtube_session_spotify
             where studio_track_id is not null) pi on pi.spotify_id = k.spotify_id and pi.track_id = k.track_id
  left join staging.spotify_artist sa on sa.spotify_id = k.spotify_id
  left join (select lower(regexp_replace(artist, '[^[:alnum:]]', '', 'g')) as akey, title_key, min(first_release) as first_release
             from staging.music_catalog_status group by 1, 2) rel on rel.akey = sa.artist_name_key and rel.title_key = k.tkey
  where k.rn <= 5
), hit as (
  -- Vic 2026-10-22: the point of an invite is a live clip of the song people are streaming NOW. A "new hit" is one of
  -- the top 5 songs that is not on NDN's YouTube and came out after the latest NDN visit (or in the last 12 months
  -- for artists new to NDN). Unknown release date: counted as new when total / daily streams < 365 (about a year old).
  select distinct on (s.spotify_id) s.spotify_id, s.title as new_hit, s.daily_streams as new_hit_daily_streams,
         s.first_release as new_hit_released
  from songs s
  left join record r using (spotify_id)
  where not s.on_ndn
    and (s.first_release > coalesce(r.latest_visit, current_date - 365)
         or (s.first_release is null and s.total_streams < 365 * s.daily_streams))
  order by s.spotify_id, s.daily_streams desc
), top_song as (
  select spotify_id, title as top_song, daily_streams as top_song_daily_streams, on_ndn as top_song_on_ndn
  from songs where rn = 1
), base as (
  select sp.*, city.ph_listeners, city.manila_baguio_listeners, chart.best_chart_rank, chart.weeks_on_chart,
         chart.chart_songs, tiktok.tiktok_handle, tiktok.tiktok_followers,
         f.fans as fans_asking, f.fans_per_1000_comments, f.tiktok_asks,
         r.ndn_youtube_videos, r.ndn_tiktok_clips, r.ndn_tiktok_index, r.ndn_youtube_index, r.last_ndn_post,
         r.latest_visit, hit.new_hit, hit.new_hit_daily_streams, hit.new_hit_released,
         ts.top_song, ts.top_song_daily_streams, ts.top_song_on_ndn,
         case when ts.top_song is null then 'No song stream data'
              when hit.new_hit is not null then 'New hit not on NDN'
              when ts.top_song_on_ndn then 'Hit already on NDN'
              else 'No new hit since last visit' end                               as hit_status,
         coalesce(city.manila_baguio_listeners, 0)
           + 0.5 * (coalesce(city.ph_listeners, 0) - coalesce(city.manila_baguio_listeners, 0)) as local_raw
  from sp
  left join city using (spotify_id)
  left join chart using (spotify_id)
  left join tiktok using (artist_name_key)
  left join mart.fan_demand_artist f using (spotify_id)
  left join record r using (spotify_id)
  left join hit using (spotify_id)
  left join top_song ts using (spotify_id)
), parts as (
  select b.*,
         case when new_hit_daily_streams is null then 0 else round(100 * percent_rank() over (
           partition by new_hit_daily_streams is null order by new_hit_daily_streams))::int end  as new_hit_hype,
         round(100 * percent_rank() over (order by coalesce(201 - best_chart_rank, 0)))::int    as momentum,
         round(100 * percent_rank() over (order by local_raw))::int                             as local_reach,
         round(100 * percent_rank() over (order by coalesce(fans_per_1000_comments, 0)))::int   as fan_demand,
         round(100 * percent_rank() over (order by coalesce(monthly_listeners, 0)))::int        as size,
         round(100 * percent_rank() over (order by coalesce(followers_per_listener, 0)))::int   as loyalty,
         case when latest_visit is null then 50 else round((
           case when ndn_tiktok_index is null then 50
                else 100 * percent_rank() over (partition by ndn_tiktok_index is null order by ndn_tiktok_index) end
         + case when ndn_youtube_index is null then 50
                else 100 * percent_rank() over (partition by ndn_youtube_index is null order by ndn_youtube_index) end
           ) / 2)::int end                                                                       as track_record
  from base b
), scored as (
  select p.*,
         round(0.25 * new_hit_hype + 0.20 * momentum + 0.15 * local_reach + 0.10 * fan_demand
               + 0.10 * track_record + 0.10 * size + 0.10 * loyalty, 1)                        as score,
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
       s.latest_visit, s.last_ndn_post, s.cooldown_until
from final s;

comment on view mart.invite_candidates is
  'Top-10-to-invite score per candidate artist (INVITE_SCORE.md weights, percentile parts 0-100) plus the raw numbers behind it. sql/025.';
