-- 036 (2026-10-23): release dates from Spotify itself. The playlists step now saves each track's album date and
-- Spotify playcount (extract_spotify.py). Release for the invite = Spotify album date of the charting version, else
-- Deezer's first release, else the earliest counted TikTok sound. (Deezer matched "ICED COFFEE O MANGO SHAKE" to 2022;
-- Spotify says 2026; Na Para Bang: Spotify 2026-02-13.) Used by the pace part (sql/035) and the group order (sql/033).

create or replace view staging.spotify_playlist_track as
select s.playlist_id, p.name as playlist, s.snapshot_date,
       (t.value ->> 'pos')::int as position, t.value ->> 'track_id' as track_id, t.value ->> 'name' as song,
       array(select a.value ->> 'id' from jsonb_array_elements(t.value -> 'artists') a(value)) as artist_ids,
       array(select a.value ->> 'name' from jsonb_array_elements(t.value -> 'artists') a(value)) as artists,
       (t.value ->> 'added_at')::timestamptz as added_at,
       -- new in sql/036
       (t.value ->> 'released')::date as released, (t.value ->> 'playcount')::bigint as playcount
from raw.spotify_playlist_snapshot s
join raw.spotify_playlists p using (playlist_id)
cross join lateral jsonb_array_elements(s.payload -> 'tracks') t(value);

create or replace view staging.invite_top30 as
with lists as (
  select t.playlist, t.position, t.song, t.track_id, t.artist_ids[1] as spotify_id, t.artists[1] as artist,
         t.released, t.playcount,
         case t.playlist when 'Top 50 - Philippines' then (51 - t.position) * 2 else greatest(101 - t.position, 0) end as points
  from staging.spotify_playlist_track t
  where t.playlist in ('Top 50 - Philippines', 'Viral Hits Philippines', 'Billboard Philippines Hot 100')
    and t.snapshot_date = (select max(x.snapshot_date) from staging.spotify_playlist_track x where x.playlist = t.playlist)
), s as (
  select l.spotify_id, staging.title_key(l.song) as title_key, min(l.song) as song, min(l.artist) as artist,
         min(l.track_id) as track_id, sum(l.points) as points,
         min(l.position) filter (where l.playlist = 'Top 50 - Philippines')          as top50_pos,
         min(l.position) filter (where l.playlist = 'Viral Hits Philippines')        as viral_pos,
         min(l.position) filter (where l.playlist = 'Billboard Philippines Hot 100') as billboard_pos,
         min(l.released) as spotify_released, max(l.playcount) as spotify_playcount
  from lists l
  where l.spotify_id in (select spotify_id from staging.opm_artist) and staging.title_key(l.song) <> ''
  group by 1, 2
), kept as (   -- sql/032: drop excluded artists / songs before taking 30, so the next songs move up
  select s.* from s
  where not exists (select 1 from raw.invite_exclude e
                    where e.active
                      and (e.spotify_id is null or e.spotify_id = s.spotify_id)
                      and (e.title_key is null or e.title_key = s.title_key))
)
select r.rank, r.song_key, r.spotify_id, r.title_key, r.song, r.artist, r.track_id, r.points, r.top50_pos, r.viral_pos,
       r.billboard_pos, r.on_ndn, r.spotify_released, r.spotify_playcount from (
  select row_number() over (order by points desc, coalesce(top50_pos, 999), coalesce(billboard_pos, 999)) as rank,
         staging.name_key(artist) || '|' || title_key as song_key, s.*,
         exists (select 1 from staging.ndn_youtube_song n
                 where n.spotify_id = s.spotify_id and (n.title_key = s.title_key or n.track_id = s.track_id)) as on_ndn
  from kept s) r
where r.rank <= 30;


------------------------------------------------------------------ invite score v3.5
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
), nv as materialized (   -- sql/034: sessions per artist, computed once
  select spotify_id, latest_visit from staging.ndn_artist_visit
), record as (
  select p.spotify_id,
         count(*) filter (where p.platform = 'YouTube')                                     as ndn_youtube_videos,
         count(*) filter (where p.platform = 'TikTok')                                      as ndn_tiktok_clips,
         percentile_cont(0.5) within group (order by p.perf_index)                          as ndn_tiktok_index,
         percentile_cont(0.5) within group (order by p.vs_series_median)
           filter (where p.platform = 'YouTube')                                            as ndn_youtube_index,
         max(p.d)                                                                           as last_ndn_post,
         -- sql/034: sessions, not batches of posts (old footage posted late is not a new visit)
         (select nv.latest_visit from nv where nv.spotify_id = p.spotify_id) as latest_visit
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
         t.billboard_pos, w.videos, w.added_7d, g.growth_4w, sc.sound_created, t.spotify_released
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
         t.top30_rank, t.top30_points, t.top50_pos, t.viral_pos, t.billboard_pos, t.spotify_released
  from (select spotify_id, title_key from t30 union select spotify_id, title_key from kw where rn = 1) s
  left join kw k on k.spotify_id = s.spotify_id and k.title_key = s.title_key
  left join t30 t on t.spotify_id = s.spotify_id and t.title_key = s.title_key
), song_status as (
  -- with "already on NDN YouTube" and release date
  select s.*,
         (p.tkey is not null or (s.track_id is not null and pi.track_id is not null)) as on_ndn,
         coalesce(s.spotify_released, rel.first_release, s.sound_created) as released   -- sql/036: Spotify first
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
         s.total_streams as new_hit_total_streams,
         -- sql/035: plays per day now vs its average per day since release (first week counted as 7 days)
         case when s.daily_streams > 0 and s.total_streams > 0 and s.released is not null
              then round(s.daily_streams::numeric
                         / (s.total_streams::numeric / greatest(current_date - s.released, 7)), 2) end as new_hit_pace,
         s.released as new_hit_released, s.tiktok_videos as new_hit_tiktok_videos,
         s.tiktok_growth_4w as new_hit_tiktok_growth_4w, s.tiktok_added_7d as new_hit_tiktok_added_7d,
         s.top30_rank as new_hit_top30_rank, s.top30_points as new_hit_top30_points, s.top50_pos as new_hit_top50_pos,
         s.viral_pos as new_hit_viral_pos, s.billboard_pos as new_hit_billboard_pos, s.on_ndn as new_hit_on_ndn,
         case when s.tiktok_videos is not null and s.daily_streams is not null then 'TikTok + Spotify'
              when s.tiktok_videos is not null then 'TikTok' else 'Spotify' end as new_hit_found_on
  from song_status s
  left join record r using (spotify_id)
  where s.top30_rank is not null          -- sql/031: any release date counts; songs NDN has go to 'Post or boost'
  order by s.spotify_id, s.on_ndn, s.top30_rank   -- the artist's highest-placed top-30 song (not on NDN first)
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
         hit.new_hit_total_streams, hit.new_hit_pace,
         hit.new_hit_tiktok_growth_4w, hit.new_hit_found_on, hit.new_hit_tiktok_added_7d,
         hit.new_hit_top30_rank, hit.new_hit_top30_points, hit.new_hit_top50_pos, hit.new_hit_viral_pos,
         hit.new_hit_billboard_pos, hit.new_hit_on_ndn,
         ts.top_song, ts.top_song_daily_streams, ts.top_song_on_ndn,
         tt.top_tiktok_song, tt.top_tiktok_song_videos,
         case when hit.new_hit is null then 'No song data'
              when hit.new_hit_on_ndn then 'Hit already on NDN'
              when r.latest_visit is not null and hit.new_hit_released > r.latest_visit
                then 'Played for NDN, song is newer'                -- sql/033: can't be in their session footage
              when r.latest_visit is not null then 'Played for NDN, song not filmed'
              else 'New hit not on NDN' end                                        as hit_status,
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
         case when new_hit_pace is null then 0 else round(100 * percent_rank() over (
           partition by new_hit_pace is null order by new_hit_pace))::int end                         as new_hit_pace_part,
         round(100 * percent_rank() over (order by coalesce(201 - best_chart_rank, 0)))::int    as momentum,
         round(100 * percent_rank() over (order by local_raw))::int                             as local_reach,
         round(100 * percent_rank() over (order by coalesce(fans_per_1000_comments, 0)))::int   as fan_demand,
         round(100 * percent_rank() over (order by coalesce(monthly_listeners, 0)))::int        as size,
         round(100 * percent_rank() over (order by coalesce(followers_per_listener, 0)))::int   as loyalty
  from base b
), scored as (
  select p.*,
         round(0.25 * tt_song_videos + 0.15 * tt_song_growth + 0.10 * tt_follower_growth + 0.05 * track_record
               + 0.075 * new_hit_hype + 0.075 * new_hit_pace_part + 0.10 * momentum + 0.05 * local_reach
               + 0.10 * fan_demand + 0.05 * size, 1)                                            as score,
         round(0.25 * tt_song_videos + 0.15 * tt_song_growth + 0.10 * tt_follower_growth + 0.05 * track_record, 1) as tiktok_points,
         round(0.075 * new_hit_hype + 0.075 * new_hit_pace_part + 0.10 * momentum + 0.05 * local_reach, 1) as spotify_points,
         round(0.10 * fan_demand + 0.05 * size, 1)                                               as other_points,
         (latest_visit + interval '10 months')::date                                            as cooldown_until
  from parts p
), final as (
  select s.*,
         case when s.hit_status in ('New hit not on NDN', 'Played for NDN, song is newer') then 'Recommend'
              else 'Post or boost' end                                              as status
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
       s.new_hit_top30_rank, s.new_hit_top30_points, s.new_hit_top50_pos, s.new_hit_viral_pos, s.new_hit_billboard_pos,
       -- new in sql/031
       coalesce(s.new_hit_on_ndn, false) as new_hit_on_ndn,
       case when s.hit_status = 'New hit not on NDN' then 'Invite to Live at The Cozy Cove'
            when s.hit_status = 'Played for NDN, song is newer'
              then 'Invite again: new song since their ' || to_char(s.latest_visit, 'Mon YYYY') || ' session'
                   || case when s.cooldown_until > current_date then ' (after ' || to_char(s.cooldown_until, 'Mon YYYY') || ')'
                           else '' end
            when s.new_hit_on_ndn then 'Boost the NDN video of this song'
            else 'Check their NDN session footage: post it if they played this song' end as action,
       nv.title as ndn_video_title, nv.url as ndn_video_link, nv.latest_views as ndn_video_views,
       -- new in sql/035
       s.new_hit_total_streams, s.new_hit_pace, s.new_hit_pace_part
from final s
left join lateral (   -- the NDN YouTube video to boost: this song's, else the artist's most viewed
  select v.title, v.url, v.latest_views from staging.video_artist va
  join mart.tableau_dim_video v on v.platform = va.platform and v.video_id = va.video_id
  where va.platform = 'YouTube' and va.spotify_id = s.spotify_id
  order by (staging.title_key(v.song) = staging.title_key(s.new_hit)) desc nulls last, v.latest_views desc nulls last
  limit 1) nv on s.status = 'Post or boost';

comment on view mart.invite_candidates is
  'Who to invite v3.5: release dates from Spotify first (sql/036).';

create or replace view mart.invite_top30_tiktok as
with rel as (
  select t.song_key,
         coalesce(t.spotify_released,
                  (select min(m.first_release) from staging.music_catalog_status m
                   where staging.name_key(m.artist) = staging.name_key(t.artist) and m.title_key = t.title_key),
                  (select min(staging.tiktok_id_date(s.music_id)) from staging.tiktok_trend_sound s
                   where s.song_key = t.song_key and s.status = 'kept')) as released
  from staging.invite_top30 t
)
select t.rank, t.song, t.artist, t.song_key, t.spotify_id, t.points, t.top50_pos, t.viral_pos, t.billboard_pos,
       w.videos as tiktok_videos, w.added_7d as videos_added_7d, round(g.growth_4w, 3) as growth_4w,
       w.sounds_kept, w.fan_sounds_kept, w.sounds_unchecked, w.counted_on,
       ts.title || ' / ' || ts.author as top_sound, ts.link as top_sound_link,
       case when w.song_key is null or w.sounds_kept = 0 then 'Waiting for the TikTok search (every 3 days)'
            when w.sounds_unchecked > 0 then 'Caption check pending'
            when g.growth_4w is null then 'Growth after a second count 6+ days later'
            else 'OK' end as to_do,
       t.on_ndn,
       -- sql/033: same order as the invite view
       case when t.on_ndn then 'Post or boost'
            when nv.latest_visit is not null and rel.released > nv.latest_visit then 'Who to invite'
            when nv.latest_visit is not null then 'Post or boost'
            else 'Who to invite' end as invite_group,
       rel.released, nv.latest_visit
from staging.invite_top30 t
join rel using (song_key)
left join staging.ndn_artist_visit nv using (spotify_id)
left join staging.tiktok_trend_song_week w using (song_key)
left join staging.tiktok_trend_song_growth g using (song_key)
left join staging.tiktok_trend_sound ts on ts.song_key = t.song_key and ts.music_id = w.top_music_id;
