-- 016: YouTube extras (2026-10-20). Data set 4, YouTube part. Questions: YOUTUBE_QUESTIONS.md.
-- Edge Function youtube-extras (Data API, same YOUTUBE_API_KEY secret as youtube-snapshot):
--   part=weekly   Mon 11:00 PH: Shorts list (hidden playlist UUSH...), NDN playlists + items (date
--                 each video was added), ~90 searches "<song> <artist>" (search.list bucket, 100/day)  Q2 Q7 Q9
--   part=chart    daily 09:10 PH: PH Trending Music list (videos.list chart=mostPopular, category 10) Q11
--   part=premiere 19:02 + 19:05 PH: concurrent viewers of a Premiere that is live right now             Q10
-- extract_youtube_heatmap.py on the home server (Mon 10:20 PH, yt-dlp needs a home IP):
--   "Most replayed" graph per long video -> part=heatmap_save                                          Q3
-- Not untouched, to save space: API replies keep only the fields listed per part below.

------------------------------------------------------------------ raw
-- One row per reply. part / item_key:
--   shorts    'UUSH'                 payload {ids: [video ids]}
--   playlists 'all'                  payload {items: [{id, title, itemCount, publishedAt}]}
--   playlist_items <playlist id>     payload {items: [{videoId, position, addedAt}]}
--   search    <target video id>      meta {q, reason}; payload {items: [{id, channelId, channelTitle, title, publishedAt}]}
--   chart     'PH_10'                payload {items: [{id, channelId, channelTitle, title, categoryId, publishedAt, views, likes}]}
--   premiere  <video id>|HH:MI UTC   payload {id, title, concurrentViewers, views, scheduledStartTime, actualStartTime}
create table if not exists raw.youtube_extras (
  snapshot_date date        not null,          -- PH date of the run
  part          text        not null,
  item_key      text        not null,
  extracted_at  timestamptz not null default now(),
  meta          jsonb,
  payload       jsonb       not null,
  primary key (snapshot_date, part, item_key)
);

-- "Most replayed" graph (yt-dlp field heatmap): 100 points [start_sec, value 0-1]. found = false:
-- YouTube shows no graph yet (too few views), fetched again later.
create table if not exists raw.youtube_heatmap (
  video_id      text        not null,
  snapshot_date date        not null,
  fetched_at    timestamptz not null default now(),
  found         boolean     not null,
  duration_sec  int,
  points        jsonb,
  primary key (video_id, snapshot_date)
);

alter table raw.youtube_extras  enable row level security;
alter table raw.youtube_heatmap enable row level security;

------------------------------------------------------------------ staging
-- Title/song key used to match NDN songs with Spotify/kworb titles: cut "(Live ...)", "[...]",
-- " - Live ..." and keep letters and digits only.
create or replace function staging.song_key(t text) returns text language sql immutable as $$
  select regexp_replace(lower(regexp_replace(coalesce(t, ''), '\s*([\(\[]| - ).*$', '')), '[^a-z0-9]', '', 'g')
$$;

-- Short or long, for every YouTube video. YouTube's own Shorts list wins; videos newer than the
-- latest list fall back to length (<= 60 s), which misses 61-180 s Shorts until the next Monday.
create or replace view staging.youtube_video_format as
with l as (
  select snapshot_date, payload->'ids' as ids from raw.youtube_extras
  where part = 'shorts' order by snapshot_date desc limit 1
)
select v.video_id, v.duration_sec, v.published_at,
       case when l.ids is not null and (v.published_at at time zone 'Asia/Manila')::date < l.snapshot_date
            then l.ids ? v.video_id else v.duration_sec <= 60 end as is_short,
       case when l.ids is not null and (v.published_at at time zone 'Asia/Manila')::date < l.snapshot_date
            then 'youtube_list' else 'length' end as flag_source
from mart.dim_video v left join l on true
where v.platform = 'YouTube';

-- Fields already in the daily raw snapshot that staging didn't expose (latest snapshot).
create or replace view staging.youtube_video_details as
select distinct on (i->>'id')
       i->>'id' as video_id, r.snapshot_date,
       i->'snippet'->>'description'                                  as description,
       (i->'contentDetails'->>'caption')::boolean                     as has_uploaded_captions,
       jsonb_array_length(coalesce(i->'snippet'->'tags', '[]'))       as tag_count,
       i->'snippet'->>'categoryId'                                    as category_id,
       i->'snippet'->>'defaultAudioLanguage'                          as audio_language,
       (i ? 'liveStreamingDetails')                                   as is_premiere,
       (i->'liveStreamingDetails'->>'scheduledStartTime')::timestamptz as premiere_scheduled,
       (i->'liveStreamingDetails'->>'actualStartTime')::timestamptz    as premiere_started,
       (i->'snippet'->>'description') ilike '%open.spotify.com%'      as links_spotify,
       (i->'snippet'->>'description') ilike '%list=%'                  as links_playlist
from raw.youtube_responses r, jsonb_array_elements(r.payload->'items') i
where r.file_name like 'videos\_%'
order by i->>'id', r.snapshot_date desc;

create or replace view staging.youtube_playlist as
select e.snapshot_date, p->>'id' as playlist_id, p->>'title' as title,
       (p->>'itemCount')::int as item_count, (p->>'publishedAt')::timestamptz as created_at
from raw.youtube_extras e, jsonb_array_elements(e.payload->'items') p
where e.part = 'playlists';

create or replace view staging.youtube_playlist_item as
select e.snapshot_date, e.item_key as playlist_id, x->>'videoId' as video_id,
       (x->>'position')::int as position, (x->>'addedAt')::timestamptz as added_at
from raw.youtube_extras e, jsonb_array_elements(e.payload->'items') x
where e.part = 'playlist_items';

-- Every search result (top 25), and one summary row per search: where NDN ranks.
create or replace view staging.youtube_search_result as
select e.snapshot_date, e.item_key as target_video_id, e.meta->>'q' as query, e.meta->>'reason' as reason,
       x.n::int as rank, x.it->>'id' as video_id, x.it->>'channelId' as channel_id,
       x.it->>'channelTitle' as channel_title, x.it->>'title' as title,
       x.it->>'channelId' = 'UCNO66UYt0xSeEMw9d5v-37w' as is_ndn
from raw.youtube_extras e,
     jsonb_array_elements(e.payload->'items') with ordinality x(it, n)
where e.part = 'search';

create or replace view staging.youtube_search_rank as
select e.snapshot_date, e.item_key as target_video_id, e.meta->>'q' as query, e.meta->>'reason' as reason,
       jsonb_array_length(e.payload->'items') as results,
       (select min(n) from jsonb_array_elements(e.payload->'items') with ordinality x(it, n)
         where x.it->>'id' = e.item_key)::int as target_rank,                  -- the session itself
       (select min(n) from jsonb_array_elements(e.payload->'items') with ordinality x(it, n)
         where x.it->>'channelId' = 'UCNO66UYt0xSeEMw9d5v-37w')::int as ndn_best_rank,   -- any NDN video
       e.payload->'items'->0->>'channelTitle' as first_channel
from raw.youtube_extras e
where e.part = 'search';

create or replace view staging.youtube_trending_ph as
select e.snapshot_date, x.n::int as rank, x.it->>'id' as video_id, x.it->>'channelId' as channel_id,
       x.it->>'channelTitle' as channel_title, x.it->>'title' as title,
       (x.it->>'publishedAt')::timestamptz as published_at,
       (x.it->>'views')::bigint as views, (x.it->>'likes')::bigint as likes,
       x.it->>'channelId' = 'UCNO66UYt0xSeEMw9d5v-37w' as is_ndn
from raw.youtube_extras e, jsonb_array_elements(e.payload->'items') with ordinality x(it, n)
where e.part = 'chart';

-- Premiere turnout: the highest live count seen for each Premiere.
create or replace view staging.youtube_premiere_turnout as
select payload->>'id' as video_id, min(payload->>'title') as title,
       max((payload->>'concurrentViewers')::int) as peak_concurrent_seen,
       min((payload->>'actualStartTime')::timestamptz) as premiere_started,
       count(*) as checks
from raw.youtube_extras where part = 'premiere'
group by 1;

-- "Most replayed": peak after the first 5% (every video starts high), its height vs the median.
create or replace view staging.youtube_heatmap_peak as
with h as (
  select distinct on (video_id) video_id, snapshot_date, duration_sec, points
  from raw.youtube_heatmap where found order by video_id, snapshot_date desc
), p as (
  select h.video_id, h.snapshot_date, h.duration_sec,
         (pt->>0)::numeric as start_sec, (pt->>1)::numeric as val
  from h, jsonb_array_elements(h.points) pt
)
select video_id, snapshot_date, duration_sec,
       (array_agg(start_sec order by val desc) filter (where start_sec >= 0.05 * duration_sec))[1] as peak_sec,
       max(val) filter (where start_sec >= 0.05 * duration_sec) as peak_value,
       percentile_cont(0.5) within group (order by val) as median_value,
       round((max(val) filter (where start_sec >= 0.05 * duration_sec)
              / nullif(percentile_cont(0.5) within group (order by val), 0))::numeric, 2) as peak_ratio
from p group by 1, 2, 3;

-- Each NDN YouTube video with a parsed song -> the artist's Spotify id (every credited artist) ->
-- the studio song on kworb or in the Spotify top 10, and a "Live at the Cozy Cove" audio version
-- if one exists. For the flagship (Q12), song choice (Q5) and the invite score (Q13).
create or replace view staging.youtube_session_spotify as
with s as (
  select v.video_id, v.title, v.song, v.artist, v.published_at, staging.song_key(v.song) as song_key, a.name_key
  from mart.dim_video v
  join staging.ndn_artist a on a.credit_key = staging.name_key(btrim(regexp_replace(v.artist, '^[-—–\s]+', '')))
  where v.platform = 'YouTube' and v.song is not null
    and (a.part_no > 0 or not exists (select 1 from staging.ndn_artist b where b.credit_key = a.credit_key and b.part_no > 0))
), kw as (
  select distinct on (spotify_id, track_id) spotify_id, track_id, title, total_streams, staging.song_key(title) as k,
         title ~* 'cozy cove' as is_cozy_cove_audio, title ~* 'live|remix|acoustic|version' as is_variant
  from staging.kworb_song order by spotify_id, track_id, snapshot_date desc
), tt as (
  select distinct on (spotify_id, track_id) spotify_id, track_id, track, staging.song_key(track) as k
  from staging.spotify_top_track order by spotify_id, track_id, snapshot_date desc
)
select s.video_id, s.title, s.published_at, s.song, s.name_key, m.spotify_id,
       st.track_id as studio_track_id, st.title as studio_title, st.total_streams as studio_streams_latest,
       lv.track_id as cozy_audio_track_id, lv.title as cozy_audio_title,
       tp.track_id as top10_track_id,
       case when st.track_id is not null then 'kworb' when tp.track_id is not null then 'spotify_top10' end as matched_in
from s
join staging.spotify_name_map m on m.name_key = s.name_key
left join lateral (select * from kw where kw.spotify_id = m.spotify_id and kw.k = s.song_key and not kw.is_variant
                   order by total_streams desc nulls last limit 1) st on true
left join lateral (select * from kw where kw.spotify_id = m.spotify_id and kw.k = s.song_key and kw.is_cozy_cove_audio
                   order by total_streams desc nulls last limit 1) lv on true
left join lateral (select * from tt where tt.spotify_id = m.spotify_id and tt.k = s.song_key limit 1) tp on true;

------------------------------------------------------------------ schedule (pg_cron, UTC)
-- weekly Mon 03:00 UTC = 11:00 PH (after trends 10:00, Deezer 10:10, heatmap 10:20, TikTok 10:30, Spotify 10:45)
select cron.schedule('ndn-youtube-extras-weekly', '0 3 * * 1', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/youtube-extras?part=weekly&by=pg_cron',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);
-- daily 01:10 UTC = 09:10 PH
select cron.schedule('ndn-youtube-chart-daily', '10 1 * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/youtube-extras?part=chart&by=pg_cron',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$$);
-- 11:02 and 11:05 UTC = 19:02 and 19:05 PH (NDN Premieres start 19:00 PH and run about 6 minutes)
select cron.schedule('ndn-youtube-premiere-check', '2,5 11 * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/youtube-extras?part=premiere&by=pg_cron',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$$);

-- Checks:
--   select part, run_by, status, detail from raw.music_runs where part like 'youtube%' order by run_id desc limit 5;
--   select * from staging.youtube_search_rank order by snapshot_date desc, ndn_best_rank nulls last;
--   select * from staging.youtube_premiere_turnout order by premiere_started desc;
