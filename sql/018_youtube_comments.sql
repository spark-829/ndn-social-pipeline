-- 018: YouTube comments (2026-10-21). Data set 5, build step 1. Plan: FAN_REQUESTS.md.
-- Edge Function youtube-comments (Data API commentThreads.list, same YOUTUBE_API_KEY secret):
--   top-level comments only (replies are conversation, requests are top-level), newest first,
--   100 per page = 1 quota unit. Works ~100 s per call (Edge Functions stop at 150 s), saves
--   progress per video and answers {more: true} until nothing is left.
-- What gets fetched: videos never fetched, videos left half-done, and videos whose comment count in the
-- daily snapshot grew since the last fetch (read newest first, stop at the newest comment already stored).
-- Kept per comment: text, times, likes, reply count, author channel id. No display name, no avatar.

------------------------------------------------------------------ raw
-- comment = {text, published_at, updated_at, likes, replies, author_channel_id}
create table if not exists raw.youtube_comments (
  comment_id text primary key,               -- the thread id = the top-level comment id
  video_id   text not null,
  fetched_at timestamptz not null default now(),
  comment    jsonb not null
);
create index if not exists youtube_comments_video on raw.youtube_comments (video_id);

-- One row per video. status: ok, partial (page_token = where to go on), disabled (comments off,
-- tried again only if the count grows), error (tried again after 6 days).
create table if not exists raw.youtube_comment_fetch (
  video_id       text primary key,
  fetched_at     timestamptz not null default now(),
  status         text not null check (status in ('ok', 'partial', 'disabled', 'error')),
  count_at_fetch int,                         -- commentCount in the daily snapshot (includes replies)
  newest_at      timestamptz,                 -- newest comment stored by a finished fetch = next stop point
  page_token     text,                        -- partial only
  run_newest_at  timestamptz,                 -- partial only: newest comment seen in the unfinished fetch
  saved          int not null default 0,      -- comments saved so far (all fetches)
  error          text
);

alter table raw.youtube_comments      enable row level security;
alter table raw.youtube_comment_fetch enable row level security;

------------------------------------------------------------------ staging
create or replace view staging.youtube_comment as
select c.comment_id, c.video_id,
       c.comment->>'text'                         as text,
       (c.comment->>'published_at')::timestamptz  as created_at,
       (c.comment->>'updated_at')::timestamptz    as updated_at,
       (c.comment->>'likes')::int                 as likes,
       (c.comment->>'replies')::int               as replies,
       c.comment->>'author_channel_id'            as author_channel_id
from raw.youtube_comments c;

-- To-do list for the Edge Function (also handy to check how much is left).
create or replace view staging.youtube_comment_todo as
with snap as (
  select distinct on (video_id) video_id, comments
  from staging.youtube_video_snapshot
  where snapshot_date >= (select max(snapshot_date) - 3 from raw.youtube_runs)
  order by video_id, snapshot_date desc
)
select v.video_id, v.published_at, s.comments as count_now, f.status, f.count_at_fetch, f.newest_at,
       f.page_token, f.run_newest_at,
       case when f.video_id is null then 'new'
            when f.status = 'partial' then 'resume'
            when f.status = 'error' then 'retry'
            else 'grew' end as reason
from mart.dim_video v
join snap s using (video_id)
left join raw.youtube_comment_fetch f using (video_id)
where v.platform = 'YouTube'
  and (f.video_id is null
       or f.status = 'partial'
       or (f.status = 'error' and f.fetched_at < now() - interval '6 days')
       or (f.status in ('ok', 'disabled') and s.comments > coalesce(f.count_at_fetch, 0)));

-- Both platforms in one shape, for the fan-request analysis (FAN_REQUESTS.md Part B).
-- author_key: TikTok handle / YouTube channel id (count distinct fans, never shown).
create or replace view staging.fan_comment as
select 'TikTok'::text as platform, cid as comment_id, video_id, text, created_at, likes, author_handle as author_key
from staging.tiktok_comment
union all
select 'YouTube', comment_id, video_id, text, created_at, likes, author_channel_id
from staging.youtube_comment;

------------------------------------------------------------------ schedule (pg_cron, UTC)
-- weekly Tue 03:30/03:35/03:40 UTC = 11:30/11:35/11:40 PH (not Monday: Monday's searches use most
-- of the quota). Calls after the work is done exit at once.
select cron.schedule('ndn-youtube-comments-weekly', '30,35,40 3 * * 2', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/youtube-comments?by=pg_cron',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);

-- One-off backfill, Wed 2026-10-21 07:30-08:57 UTC = 15:30-16:57 PH (YouTube quota resets 15:00 PH),
-- every 3 minutes. A cleanup job at 09:05 UTC (17:05 PH) removes it and itself (the tracker would
-- otherwise read it as a daily job and show it Down). Anything left over: Tuesday's weekly run.
select cron.schedule('ndn-youtube-comments-backfill', '*/3 7-8 21 10 *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/youtube-comments?by=backfill',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);
select cron.schedule('ndn-youtube-comments-backfill-cleanup', '5 9 21 10 *', $$
  select cron.unschedule('ndn-youtube-comments-backfill');
  select cron.unschedule('ndn-youtube-comments-backfill-cleanup');
$$);

-- Tested 2026-10-21 04:00 PH (10 units): 8 videos; top-level + replies = commentCount; a video that
-- "grew" read 1 page and saved exactly the 3 missing comments; a 226-comment video took 3 pages.

-- Checks:
--   select part, run_by, status, detail from raw.music_runs where part = 'youtube_comments' order by run_id desc limit 5;
--   select reason, count(*), sum(count_now) from staging.youtube_comment_todo group by 1;
--   select status, count(*), sum(saved) from raw.youtube_comment_fetch group by 1;
--   select pg_size_pretty(pg_total_relation_size('raw.youtube_comments'));
