-- 020_benchmarks.sql  (data set 6: benchmark accounts; brief NDN_Social_Pipeline/BENCHMARKS.md)
-- Scope (Vic 2026-10-21): small on purpose, to save database space.
--   Daily : account totals only, one row per account per platform        -> raw.benchmark_daily
--   Weekly: counts for each account's latest 50 uploads per platform     -> raw.benchmark_video_weekly
--           (title etc. stored once per video in raw.benchmark_video); top 10 = most views gained
--           since the previous weekly snapshot, scaled to 7 days.
-- Collected by the Edge Function `benchmarks` (YouTube Data API + Instagram Business Discovery,
-- pg_cron) and by extract_benchmarks_tiktok.py (GitHub Actions, posts through the same function).
-- All public data; label as "independent analysis of public data".

create table if not exists raw.benchmark_accounts (
  account_key        text primary key,
  name               text not null,
  tiktok_handle      text,            -- without @
  youtube_channel_id text,
  instagram_username text,
  given_by           text not null,
  active             boolean not null default true,
  note               text
);

create table if not exists raw.benchmark_daily (
  snapshot_date date        not null,  -- PH date
  account_key   text        not null references raw.benchmark_accounts,
  platform      text        not null check (platform in ('TikTok', 'YouTube', 'Instagram')),
  followers     bigint,                -- TikTok followers, YouTube subscribers (rounded by YouTube), IG followers
  total_views   bigint,                -- YouTube channel views (TikTok and Instagram don't publish one)
  total_likes   bigint,                -- TikTok hearts
  posts         int,                   -- videos / posts on the account
  fetched_at    timestamptz not null default now(),
  primary key (snapshot_date, account_key, platform)
);

create table if not exists raw.benchmark_video (
  platform     text not null,
  video_id     text not null,
  account_key  text not null references raw.benchmark_accounts,
  published_at timestamptz,
  title        text,                   -- first 150 characters of title / caption
  url          text,
  kind         text,                   -- YouTube: video; Instagram: REELS/FEED; TikTok: video
  first_seen   date not null,
  primary key (platform, video_id)
);

create table if not exists raw.benchmark_video_weekly (
  snapshot_date date   not null,       -- PH date of the weekly run
  platform      text   not null,
  video_id      text   not null,
  views         bigint,                -- Instagram: Reels only (view_count)
  likes         bigint,
  comments      bigint,
  primary key (snapshot_date, platform, video_id)
);

alter table raw.benchmark_accounts     enable row level security;
alter table raw.benchmark_daily        enable row level security;
alter table raw.benchmark_video        enable row level security;
alter table raw.benchmark_video_weekly enable row level security;

-- Handles found from each account's own bio / YouTube links / website (checked 2026-10-21), not guessed.
insert into raw.benchmark_accounts (account_key, name, tiktok_handle, youtube_channel_id, instagram_username, given_by, note) values
  ('wish',     'Wish 107.5 (Wish Bus)', 'wish1075official', 'UCdfq8-581QVUtVsa8ChVnDQ', 'wish1075',      'Claude 2026-10-20',
   'The leader: 16.1M YouTube subscribers. Ranks in 62 of NDN''s 90 weekly song searches.'),
  ('jesspats', 'Jess & Pat''s',          'jessxpats',        'UCPBPWR8nuHPKt5X_qPk3t1A', 'jessxpats',     'Vic 2026-10-21',
   'Gig cafe, Maginhawa QC. YouTube inactive since May 2020 (totals still tracked).'),
  ('backyard', 'Backyard Live',         'backyard.live',    'UC1P5pdk6RAUJqaIRPUC0jWg', 'backyard.live', 'Vic 2026-10-21',
   'Up-close 360 concert sessions, QC. Small and growing.'),
  ('tower',    'Tower of Doom (Tower Sessions)', null,      'UCh__YhmGdnvPh5fSdF8DJnQ', 'towerofdoom',   'Claude 2026-10-21 (proposed, Vic to OK)',
   'Closest peer: indie OPM studio live sessions, 1.21M subscribers vs NDN 1.51M; avg rank 5.3 in NDN''s song searches. No TikTok listed on its YouTube page or website.'),
  ('vibe',     'Vibe PH (Vibe+)',       'vibeph.tv',        'UC6hmtt5JtP0e_FNAtWsq2Yw', 'vibeph.tv',     'Claude 2026-10-21 (proposed, Vic to OK)',
   'Fast riser: TV5 all-OPM countdown with live performances, channel started Apr 2025; in 12 of NDN''s song searches.')
on conflict (account_key) do nothing;

-- The weekly TikTok profile job (tiktok-extras) stops snapshotting benchmark accounts:
-- their totals now come daily through raw.benchmark_daily.
update raw.tiktok_accounts set active = false,
       note = coalesce(note, '') || ' | moved to raw.benchmark_daily (sql/020)'
where role = 'benchmark' and active;

------------------------------------------------------------------ views
-- Daily totals of every benchmark plus NDN, with growth indexed to 100 on each account's first day.
create or replace view mart.benchmark_growth as
with d as (
  select b.snapshot_date, b.account_key, a.name, b.platform, b.followers, b.total_views, b.total_likes, b.posts
  from raw.benchmark_daily b join raw.benchmark_accounts a using (account_key)
  union all
  select f.snapshot_date, 'ndn', 'Nine Degrees North', f.platform, f.followers, f.total_views, f.hearts, f.video_count
  from mart.fact_account_daily f
  where f.data_source = 'real'
    and f.snapshot_date >= (select min(snapshot_date) from raw.benchmark_daily)
)
select d.*,
       round(100.0 * d.followers / nullif(first_value(d.followers) over w, 0), 2) as followers_index,
       d.followers - lag(d.followers) over (partition by d.account_key, d.platform order by d.snapshot_date) as followers_gained
from d
window w as (partition by d.account_key, d.platform order by d.snapshot_date);

-- Weekly: views gained per video since the previous weekly snapshot, scaled to 7 days.
-- A video new since the last run counts all its views as gained. The first week has no gain yet.
-- measure: 'views', or 'likes' for an account whose views don't come back (Instagram hides Reel
-- views for some accounts: Backyard Live and Vibe PH, 2026-10-21). On Instagram with views,
-- only Reels have views, so photo posts drop out of that account's ranking.
create or replace view mart.benchmark_video_gain as
with s as (
  select s.*, v.account_key, v.title, v.url, v.kind, v.published_at,
         bool_or(s.views is not null) over (partition by s.snapshot_date, s.platform, v.account_key) as has_views
  from raw.benchmark_video_weekly s
  join raw.benchmark_video v using (platform, video_id)
), w as (
  select s.*, case when has_views then 'views' else 'likes' end as measure,
         case when has_views then views else likes end as value,
         lag(s.snapshot_date) over p as prev_date,
         lag(case when has_views then views else likes end) over p as prev_value
  from s
  window p as (partition by s.platform, s.video_id order by s.snapshot_date)
), runs as (
  select platform, account_key, snapshot_date,
         lag(snapshot_date) over (partition by platform, account_key order by snapshot_date) as prev_run
  from (select distinct w.platform, w.account_key, w.snapshot_date from w) r
), g as (
  select w.*, r.prev_run,
         case when r.prev_run is null then null
              when w.prev_date = r.prev_run then w.value - w.prev_value
              when w.published_at >= r.prev_run then w.value                -- new since last run
         end as gained
  from w join runs r using (platform, account_key, snapshot_date)
)
select g.snapshot_date, g.platform, g.account_key, a.name, g.video_id, g.title, g.url, g.kind, g.published_at,
       g.views, g.likes, g.comments, g.measure, g.prev_run, g.gained,
       round(7.0 * g.gained / nullif(g.snapshot_date - g.prev_run, 0)) as gained_7d
from g join raw.benchmark_accounts a using (account_key);

-- Top 10 trending per account and platform, latest weekly run.
create or replace view mart.benchmark_top10 as
with latest as (
  select g.* from (select g.*, max(g.snapshot_date) over (partition by g.platform, g.account_key) as latest_run
                   from mart.benchmark_video_gain g) g
  where g.snapshot_date = g.latest_run and g.gained_7d is not null
)
select * from (
  select l.*, row_number() over (partition by l.platform, l.account_key order by l.gained_7d desc, l.views desc nulls last) as rank
  from latest l
) t where rank <= 10;

comment on view mart.benchmark_growth is 'Daily account totals: benchmarks + NDN (real data only), followers indexed to 100 on the first day (sql/020).';
comment on view mart.benchmark_top10 is 'Top 10 videos per benchmark account and platform by views gained (likes if views are hidden; see measure) in the last weekly period, scaled to 7 days (sql/020).';

------------------------------------------------------------------ schedule (applied 2026-10-21)
-- Daily 09:20 PH = 01:20 UTC; weekly Monday 11:20 PH = 03:20 UTC (after youtube-extras at 11:00).
-- TikTok runs on GitHub: daily.yml (after the NDN snapshot) and weekly.yml (Monday 10:30 PH).
select cron.schedule('ndn-benchmarks-daily', '20 1 * * *', $$
    select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
               || '/functions/v1/benchmarks?step=daily&by=pg_cron',
        headers := jsonb_build_object('Content-Type', 'application/json',
            'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
        body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);
select cron.schedule('ndn-benchmarks-weekly', '20 3 * * 1', $$
    select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
               || '/functions/v1/benchmarks?step=weekly&by=pg_cron',
        headers := jsonb_build_object('Content-Type', 'application/json',
            'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
        body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);
