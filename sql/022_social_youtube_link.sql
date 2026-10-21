-- 022_social_youtube_link.sql (2026-10-21, INSTAGRAM_QUESTIONS.md gap list row 5: Q6, Q12; also TikTok)
-- One row per Instagram or TikTok post whose caption names a song: the YouTube session it promotes
-- and that session's Spotify match (staging.youtube_session_spotify).
-- Match rule, best first:
--   'song+artist'    same song_key ("song|artist") on a long YouTube video, nearest upload date
--   'song, 60 days'  same song title, different artist spelling, uploaded within 60 days
-- First run: Instagram 444 of 521 posts with a song matched (400 exact), TikTok 432 of 513 (384);
-- median gap 0 days. Unmatched: mostly ticket/event captions read as songs, or Spotify-only
-- releases with no YouTube session.

create or replace view staging.social_youtube_link as
with d as materialized (
  select platform, video_id, published_at, song, artist, song_key, split_part(song_key, '|', 1) as sk, format
  from mart.dim_video
  where song is not null and song_key <> '|'
), y as materialized (
  select * from d where platform = 'YouTube' and format is distinct from 'Short'
)
select d.platform,
       d.video_id                                  as post_id,
       d.published_at,
       d.song,
       d.artist,
       l.video_id                                  as youtube_video_id,
       l.match_rule,
       round((extract(epoch from d.published_at - l.published_at) / 86400)::numeric, 1)
                                                   as gap_days,         -- + = post after the YouTube upload
       s.spotify_id,
       s.studio_track_id,
       s.studio_streams_latest,
       s.cozy_audio_track_id,
       s.matched_in                                as spotify_matched_in
from d
left join lateral (
  select y.video_id, y.published_at,
         case when y.song_key = d.song_key then 'song+artist' else 'song, 60 days' end as match_rule
  from y
  where y.song_key = d.song_key
     or (y.sk = d.sk and length(d.sk) >= 4
         and abs(extract(epoch from d.published_at - y.published_at)) < 60 * 86400)
  order by (y.song_key = d.song_key) desc, abs(extract(epoch from d.published_at - y.published_at))
  limit 1
) l on true
left join lateral (                                -- multi-artist sessions have one row per artist
  select * from staging.youtube_session_spotify s
  where s.video_id = l.video_id
  order by s.studio_track_id is null, s.studio_streams_latest desc nulls last
  limit 1
) s on true
where d.platform in ('Instagram', 'TikTok');

comment on view staging.social_youtube_link is
  'Instagram/TikTok post -> YouTube session it promotes -> Spotify track (sql/022).';
