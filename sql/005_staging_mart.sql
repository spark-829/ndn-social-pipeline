-- 005_staging_mart.sql  (Step 3: Transform)
-- raw JSON  ->  staging (one tidy row per snapshot x video, numbers as numbers)
--           ->  mart (star schema for Tableau: dim_video + fact_video_daily + fact_account_daily)
-- All objects are VIEWS: nothing is stored twice, and they always reflect the latest raw data.
-- mart facts combine REAL snapshots with the SYNTHETIC backfill; the column data_source says which.

create schema if not exists staging;
create schema if not exists mart;

------------------------------------------------------------------ staging: real snapshots, typed
create or replace view staging.youtube_video_snapshot as
select distinct on (r.snapshot_date, i->>'id')
       r.snapshot_date,
       i->>'id'                                                        as video_id,
       i->'snippet'->>'title'                                          as title,
       (i->'snippet'->>'publishedAt')::timestamptz                     as published_at,
       extract(epoch from (i->'contentDetails'->>'duration')::interval)::int as duration_sec,   -- ISO 8601 PT3M41S -> 221
       (i->'statistics'->>'viewCount')::bigint                         as views,                -- counts arrive as text
       (i->'statistics'->>'likeCount')::bigint                         as likes,                -- null = hidden by creator
       (i->'statistics'->>'commentCount')::bigint                      as comments
from raw.youtube_responses r, jsonb_array_elements(r.payload->'items') i
where r.file_name like 'videos\_%'
order by r.snapshot_date, i->>'id';

create or replace view staging.youtube_channel_snapshot as
select r.snapshot_date,
       (s->>'subscriberCount')::bigint as subscribers,
       (s->>'viewCount')::bigint       as total_views,
       (s->>'videoCount')::int         as video_count
from raw.youtube_responses r, lateral (select r.payload->'items'->0->'statistics' as s) x
where r.file_name = 'channel';

create or replace view staging.tiktok_video_snapshot as
select distinct on (r.snapshot_date, e->>'id')
       r.snapshot_date,
       e->>'id'                                        as video_id,
       coalesce(e->>'title', e->>'description')       as caption,
       e->>'url'                                       as url,
       to_timestamp((e->>'timestamp')::bigint)         as published_at,
       (e->>'duration')::numeric::int                  as duration_sec,
       (e->>'view_count')::bigint                      as views,       -- TikTok rounds >= 10,000 to 3 digits
       (e->>'like_count')::bigint                      as likes,
       (e->>'comment_count')::bigint                   as comments,
       (e->>'repost_count')::bigint                    as shares,
       (e->>'save_count')::bigint                      as saves
from raw.tiktok_responses r, jsonb_array_elements(r.payload->'entries') e
where r.file_name = 'videos' and e->>'timestamp' is not null
order by r.snapshot_date, e->>'id';

create or replace view staging.tiktok_account_snapshot as
select r.snapshot_date,
       (s->>'followerCount')::bigint as followers,        -- statsV2 = exact (stats is rounded)
       (s->>'heartCount')::bigint    as hearts,
       (s->>'videoCount')::int       as video_count
from raw.tiktok_responses r, lateral (select r.payload->'userInfo'->'statsV2' as s) x
where r.file_name = 'profile';

------------------------------------------------------------------ title parsing
-- "Song (Live at The Cozy Cove) - Artist", "Song (The Cozy Cove Fest) - Artist", "Song (Live at X) by Artist",
-- TikTok "Song (Live at The Cozy Cove) by Artist is now streaming ...", or plain "Song - Artist".
-- The session is the LAST bracketed part before " - Artist" / " by Artist", so "(Acoustic)" inside a song stays.
create or replace function mart.parse_title(t text,
    out song text, out session text, out artist text, out series text)
language plpgsql immutable set search_path = '' as $$
declare m text[];
begin
  m := regexp_match(t, '^(.*\S)\s*\(([^()]*)\)\s*(?:-|–|by)\s+(.+)$', 'i');
  if m is not null then
    song := m[1]; session := m[2]; artist := m[3];
  else
    m := regexp_match(t, '^([^\n]*\S)\s+(?:-|–)\s+([^\n]+)$');
    if m is not null then song := m[1]; artist := m[2]; end if;
  end if;
  -- TikTok captions continue after the artist: cut at the first sentence ending, hashtag or line break
  artist := regexp_replace(artist, '\s+(is now|is out|now streaming|out now|premieres|streaming|available|drops|watch|full)\M.*$', '', 'i');
  artist := regexp_replace(artist, '\s*[!#\n].*$', '');
  artist := nullif(btrim(regexp_replace(artist, '[\s.,;:]+$', '')), '');
  song   := nullif(btrim(song), '');
  series := case
    when session ~* 'cozy cove fest'          then 'The Cozy Cove Fest'
    when session ~* 'cozy cove'               then 'Live at The Cozy Cove'
    when session ~* '^\s*live (at|from|in)\M' then 'Other live shows'
    when song is not null                     then 'Other releases'
    else 'Other' end;
end;
$$;

------------------------------------------------------------------ mart: dimension
create or replace view mart.dim_video as
with yt_latest as (
  select distinct on (video_id) * from staging.youtube_video_snapshot order by video_id, snapshot_date desc
), tt_latest as (
  select distinct on (video_id) * from staging.tiktok_video_snapshot order by video_id, snapshot_date desc
), unioned as (
  select 'YouTube' as platform, y.video_id, y.title as title,
         'https://www.youtube.com/watch?v=' || y.video_id as url,
         y.published_at, y.duration_sec,
         case when y.duration_sec <= 60 then 'Short (<=60 s)' else 'Full video' end as format,
         y.views as latest_views, y.likes as latest_likes, y.comments as latest_comments,
         y.snapshot_date as latest_snapshot
  from yt_latest y
  union all
  select 'TikTok', t.video_id, t.caption, t.url, t.published_at, t.duration_sec, 'TikTok clip',
         t.views, t.likes, t.comments, t.snapshot_date
  from tt_latest t
)
select u.platform, u.video_id, u.title, u.url,
       u.published_at,
       (u.published_at at time zone 'Asia/Manila')::date              as published_date_ph,
       to_char(u.published_at at time zone 'Asia/Manila', 'Dy')        as published_weekday_ph,
       extract(isodow from u.published_at at time zone 'Asia/Manila')::int as published_weekday_num,
       extract(hour from u.published_at at time zone 'Asia/Manila')::int   as published_hour_ph,
       u.duration_sec, u.format,
       p.series, p.session, p.song, p.artist,
       lower(regexp_replace(coalesce(p.song, ''), '[^[:alnum:]]', '', 'g'))
         || '|' || lower(regexp_replace(coalesce(p.artist, ''), '[^[:alnum:]]', '', 'g')) as song_key,
       (u.title ~* 'cozy cove')                                         as mentions_cozy_cove,
       u.latest_views, u.latest_likes, u.latest_comments, u.latest_snapshot
from unioned u
cross join lateral mart.parse_title(u.title) p;

------------------------------------------------------------------ mart: daily video facts (real + synthetic)
create or replace view mart.fact_video_daily as
with yt as (
  select 'YouTube' as platform, video_id, snapshot_date, views, likes, comments,
         null::bigint as shares, null::bigint as saves, 'real' as data_source
  from staging.youtube_video_snapshot
  union all
  select 'YouTube', video_id, snapshot_date, views, likes, comments, null, null, 'synthetic'
  from synthetic.youtube_video_daily
  where snapshot_date < (select min(snapshot_date) from raw.youtube_runs)
), tt as (
  select 'TikTok', video_id, snapshot_date, views, likes, comments, shares, saves, 'real'
  from staging.tiktok_video_snapshot
  union all
  select 'TikTok', video_id, snapshot_date, views, likes, comments, shares, saves, 'synthetic'
  from synthetic.tiktok_video_daily
  where snapshot_date < (select min(snapshot_date) from raw.tiktok_runs)
), allrows as (select * from yt union all select * from tt)
select a.platform, a.video_id, a.snapshot_date, a.data_source,
       a.views, a.likes, a.comments, a.shares, a.saves,
       a.views - lag(a.views) over w                                    as views_gained,
       a.likes - lag(a.likes) over w                                    as likes_gained,
       a.snapshot_date - (d.published_at at time zone 'UTC')::date      as days_since_upload
from allrows a
join mart.dim_video d on d.platform = a.platform and d.video_id = a.video_id
window w as (partition by a.platform, a.video_id order by a.snapshot_date);

------------------------------------------------------------------ mart: daily account facts (real + synthetic)
create or replace view mart.fact_account_daily as
with rows_ as (
  select 'YouTube' as platform, snapshot_date, subscribers as followers, total_views, video_count,
         null::bigint as hearts, 'real' as data_source
  from staging.youtube_channel_snapshot
  union all
  select 'YouTube', snapshot_date, subscribers, total_views, video_count, null, 'synthetic'
  from synthetic.youtube_channel_daily
  where snapshot_date < (select min(snapshot_date) from raw.youtube_runs)
  union all
  select 'TikTok', snapshot_date, followers, null, video_count, hearts, 'real'
  from staging.tiktok_account_snapshot
  union all
  select 'TikTok', snapshot_date, followers, null, video_count, hearts, 'synthetic'
  from synthetic.tiktok_account_daily
  where snapshot_date < (select min(snapshot_date) from raw.tiktok_runs)
)
select r.*,
       r.followers   - lag(r.followers)   over w as followers_gained,
       r.total_views - lag(r.total_views) over w as views_gained
from rows_ r
window w as (partition by r.platform order by r.snapshot_date);

comment on view mart.fact_video_daily is
  'Daily views per video. data_source = real (raw snapshots) or synthetic (invented backfill before the first real snapshot).';
comment on view mart.fact_account_daily is
  'Daily channel/account totals. data_source = real or synthetic. YouTube subscribers are rounded by YouTube.';
