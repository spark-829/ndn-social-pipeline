-- STEP 5 (Transform): Instagram into staging + mart, next to YouTube and TikTok.
-- Replaces the three mart views from 005_staging_mart.sql (same columns, Instagram rows added).
-- Instagram has no views via Business Discovery, so views/views_gained are null; likes are the main metric.
-- Posts with hidden like counts have likes = null (not 0). No synthetic backfill for Instagram.

------------------------------------------------------------------ staging
create or replace view staging.instagram_post_snapshot as
select distinct on (r.snapshot_date, e->>'id')
       r.snapshot_date,
       e->>'id'                                   as post_id,
       e->>'caption'                              as caption,
       e->>'permalink'                            as url,
       (e->>'timestamp')::timestamptz             as published_at,
       e->>'media_type'                           as media_type,        -- IMAGE, VIDEO, CAROUSEL_ALBUM
       e->>'media_product_type'                   as product_type,      -- FEED, REELS
       (e->>'like_count')::bigint                 as likes,             -- null = likes hidden by NDN
       (e->>'comments_count')::bigint             as comments
from raw.instagram_responses r,
     jsonb_array_elements(r.payload->'business_discovery'->'media'->'data') e
order by r.snapshot_date, e->>'id';

create or replace view staging.instagram_account_snapshot as
select r.snapshot_date,
       (b->>'followers_count')::bigint as followers,
       (b->>'follows_count')::int      as follows,
       (b->>'media_count')::int        as media_count
from raw.instagram_responses r, lateral (select r.payload->'business_discovery' as b) x
where r.file_name = 'media_001';                                   -- page 1 carries the profile fields

------------------------------------------------------------------ mart: dimension
create or replace view mart.dim_video as
with yt_latest as (
  select distinct on (video_id) * from staging.youtube_video_snapshot order by video_id, snapshot_date desc
), tt_latest as (
  select distinct on (video_id) * from staging.tiktok_video_snapshot order by video_id, snapshot_date desc
), ig_latest as (
  select distinct on (post_id) * from staging.instagram_post_snapshot order by post_id, snapshot_date desc
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
  union all
  select 'Instagram', i.post_id, i.caption, i.url, i.published_at, null::int,
         case when i.product_type = 'REELS' then 'Instagram Reel'
              when i.media_type = 'CAROUSEL_ALBUM' then 'Instagram carousel'
              else 'Instagram post' end,
         null::bigint, i.likes, i.comments, i.snapshot_date
  from ig_latest i
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
), ig as (
  select 'Instagram', post_id, snapshot_date, null::bigint, likes, comments, null::bigint, null::bigint, 'real'
  from staging.instagram_post_snapshot
), allrows as (select * from yt union all select * from tt union all select * from ig)
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
  union all
  select 'Instagram', snapshot_date, followers, null, media_count, null, 'real'
  from staging.instagram_account_snapshot
)
select r.*,
       r.followers   - lag(r.followers)   over w as followers_gained,
       r.total_views - lag(r.total_views) over w as views_gained
from rows_ r
window w as (partition by r.platform order by r.snapshot_date);

comment on view mart.fact_video_daily is
  'Daily metrics per video/post. data_source = real (raw snapshots) or synthetic (invented backfill before the first real snapshot; YouTube/TikTok only). Instagram: no views, likes null when hidden.';
comment on view mart.fact_account_daily is
  'Daily account totals per platform. data_source = real or synthetic. YouTube subscribers are rounded by YouTube.';
