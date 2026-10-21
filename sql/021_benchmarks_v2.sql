-- 021_benchmarks_v2.sql  (Vic 2026-10-21: redo the benchmark set; replaces the account list of sql/020)
-- 5 accounts in 3 groups:  domestic = Wish 107.5, Backyard Live
--                          asia     = THE FIRST TAKE (Japan), it's Live (Korea)
--                          international = NPR Music (Tiny Desk)
-- Dropped (kept, inactive, so their one day of data is not lost): Jess & Pat's, Tower of Doom, Vibe PH.
-- Past data (Vic: real past data beats synthetic): a one-time catalog of every upload (date + today's
-- counts) per account and platform, so each account's real upload history is there from day one.
-- Instagram catalog stops at 2024-01-01 (Wish alone has 28,700 posts). Follower history before
-- 2026-10-21 is not free: Social Blade shows 14 days (more is paid), the Wayback Machine is blocked
-- on Vic's network (DNS, PC and server).

alter table raw.benchmark_accounts add column if not exists region text
  check (region in ('domestic', 'asia', 'international'));

update raw.benchmark_accounts set active = false, note = coalesce(note, '') || ' | dropped by Vic 2026-10-21 (sql/021)'
where account_key in ('jesspats', 'tower', 'vibe');
update raw.benchmark_accounts set region = 'domestic' where account_key in ('wish', 'backyard');

-- Handles from each channel's own YouTube links page; TikTok accounts checked verified 2026-10-21.
insert into raw.benchmark_accounts (account_key, name, tiktok_handle, youtube_channel_id, instagram_username, given_by, region, note) values
  ('firsttake', 'THE FIRST TAKE', 'the_first_take', 'UC9zY_E8mcAo_Oq772LEZq8Q', 'the_firsttake', 'Vic 2026-10-21', 'asia',
   'Japan. One-take performances in a white studio; 12.4M YouTube subscribers.'),
  ('itslive',   'it''s Live',     'itslive_official', 'UCB9e3pof1o83aa0kkaoeJGA', 'itslive_official', 'Vic 2026-10-21', 'asia',
   'Korea (MBC). Live band sessions, mostly K-pop; 2.34M YouTube subscribers.'),
  ('npr',       'NPR Music (Tiny Desk)', 'npr_music', 'UC4eYXhJI4-7wSWc8UNRwD4A', 'nprmusic', 'Vic 2026-10-21', 'international',
   'US. Tiny Desk Concerts live on the NPR Music channel (no separate Tiny Desk channel), so totals include other NPR Music videos. TikTok @npr_music started Feb 2026.')
on conflict (account_key) do update set name = excluded.name, tiktok_handle = excluded.tiktok_handle,
  youtube_channel_id = excluded.youtube_channel_id, instagram_username = excluded.instagram_username,
  given_by = excluded.given_by, region = excluded.region, note = excluded.note, active = true;

------------------------------------------------------------------ views: active accounts only, with region
create or replace view mart.benchmark_growth as
with d as (
  select b.snapshot_date, b.account_key, a.name, a.region, b.platform, b.followers, b.total_views, b.total_likes, b.posts
  from raw.benchmark_daily b join raw.benchmark_accounts a using (account_key)
  where a.active
  union all
  select f.snapshot_date, 'ndn', 'Nine Degrees North', 'ndn', f.platform, f.followers, f.total_views, f.hearts, f.video_count
  from mart.fact_account_daily f
  where f.data_source = 'real'
    and f.snapshot_date >= (select min(snapshot_date) from raw.benchmark_daily)
)
select d.snapshot_date, d.account_key, d.name, d.platform, d.followers, d.total_views, d.total_likes, d.posts,
       round(100.0 * d.followers / nullif(first_value(d.followers) over w, 0), 2) as followers_index,
       d.followers - lag(d.followers) over (partition by d.account_key, d.platform order by d.snapshot_date) as followers_gained,
       d.region
from d
window w as (partition by d.account_key, d.platform order by d.snapshot_date);

-- Real upload history from the catalog: per account, platform and month of upload, how many uploads
-- and how many views they have now (latest count we hold for each video). Older months have had
-- longer to collect views, so compare accounts within the same month, not months with each other.
create or replace view mart.benchmark_upload_history as
with latest as (
  select distinct on (w.platform, w.video_id) w.platform, w.video_id, w.views, w.likes, w.comments, w.snapshot_date
  from raw.benchmark_video_weekly w
  order by w.platform, w.video_id, w.snapshot_date desc
)
select v.account_key, a.name, a.region, v.platform,
       date_trunc('month', v.published_at at time zone 'Asia/Manila')::date as upload_month,
       count(*)                                                as uploads,
       sum(l.views)                                            as views_now,
       percentile_cont(0.5) within group (order by l.views)    as median_views,
       max(l.views)                                            as best_views,
       sum(l.likes)                                            as likes_now
from raw.benchmark_video v
join latest l using (platform, video_id)
join raw.benchmark_accounts a using (account_key)
where a.active and v.published_at is not null
group by 1, 2, 3, 4, 5;

comment on view mart.benchmark_upload_history is
  'Real upload history of the benchmark accounts: uploads and current views per month of upload (catalog pulled 2026-10-21, sql/021).';

-- Top 10: active accounts only (same columns as sql/020).
create or replace view mart.benchmark_top10 as
with latest as (
  select g.* from (select g.*, max(g.snapshot_date) over (partition by g.platform, g.account_key) as latest_run
                   from mart.benchmark_video_gain g
                   where g.account_key in (select account_key from raw.benchmark_accounts where active)) g
  where g.snapshot_date = g.latest_run and g.gained_7d is not null
)
select * from (
  select l.*, row_number() over (partition by l.platform, l.account_key order by l.gained_7d desc, l.views desc nulls last) as rank
  from latest l
) t where rank <= 10;
