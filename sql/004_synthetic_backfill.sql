-- 004_synthetic_backfill.sql
-- SYNTHETIC history: 304 days (about 10 months) of daily YouTube and TikTok numbers BEFORE the first real
-- snapshot, so dashboards and Step 3 can be built and tested on a long series. Real data starts
-- 2026-10-12 (YouTube) and 2026-10-13 (TikTok) in the raw schema; everything here is invented and lives
-- only in the `synthetic` schema. Never mix it into raw.
--
-- Model (per video), calibrated on REAL day-over-day growth (2026-10-13 -> 10-14, ~1,900 videos):
--   real daily growth / total views, by age:      0-7d   7-30d  30-90d  90-365d  1y+
--     YouTube full videos                         13.9%  3.1%   0.93%   0.22%    0.054%
--     YouTube Shorts                               8.9%  1.5%   0.69%   0.13%    0.037%
--     TikTok                                      13.2%  0.7%   0.10%   ~0       ~0
--   YouTube: growth x age is roughly constant (0.45 full, 0.28 Shorts) => power law:
--     f(a) = (a / a_anchor)^k,  k log-normal around 0.45 (full) or 0.28 (Shorts), spread 0.35
--   TikTok: fast burst, then nearly flat:
--     g(a) = (1 - w) * (1 - exp(-a / tau)) + w * (a / a_anchor)^0.5,  tau ~ 4 days log-normal, w 5-20%
--     f(a) = g(a) / g(a_anchor)
--   a = age in days at the 01:00 UTC snapshot (no rows before upload); f(a_anchor) = 1.
--   daily gain = real views at anchor * (f(a) - f(a - 1)) * day noise (+-25% YouTube, +-35% TikTok);
--   total on day d = real views at anchor - all gains after d, so totals only rise and end exactly
--   on the real count (no jump where synthetic meets real data).
--   likes = real likes * (views share)^0.9, comments ^0.8, shares/saves ^0.9 (engagement comes a bit earlier).
-- Account level is derived from the videos so totals always agree:
--   channel views = real channel views - (real video views - synthetic video views that day)
--   subscribers / followers fall back in proportion to the views not yet earned.
-- TikTok counts >= 10,000 are rounded down to 3 significant digits, as TikTok shows them;
-- YouTube subscribers likewise.
-- Randomness is a hash of (seed, video id, date), so the same seed always rebuilds identical data.
-- Built 2026-10-14 with the BATCHED functions in 004d_synthetic_batched.sql (rebuild() below is retired:
-- one huge statement ran out of memory). Docs: SYNTHETIC_BACKFILL.md.
-- Old note: empty the four synthetic tables, then select synthetic.rebuild('ndn-v1');
-- It takes ~2-3 min, longer than the 2-min query limit, so run it as a one-off pg_cron job with
-- statement_timeout = 0 (see STEP3 notes). exp() is clamped at -50 to avoid float underflow.

create schema if not exists synthetic;
comment on schema synthetic is
  'SYNTHETIC (invented) history for testing and demos. Not real Nine Degrees North data. See sql/004_synthetic_backfill.sql.';

-- Uniform random number in [0, 1) from any text key (same key -> same number).
create or replace function synthetic.urand(key text) returns double precision
language sql immutable parallel safe set search_path = '' as $$
  select (('x' || substr(md5(key), 1, 8))::bit(32)::bigint)::double precision / 4294967296.0
$$;

-- Standard normal random number from a text key (Box-Muller).
create or replace function synthetic.nrand(key text) returns double precision
language sql immutable parallel safe set search_path = '' as $$
  select sqrt(-2 * ln(greatest(synthetic.urand(key || ':a'), 1e-12))) * cos(2 * pi() * synthetic.urand(key || ':b'))
$$;

-- Round down to 3 significant digits when >= 10,000 (how TikTok and YouTube display big counts).
create or replace function synthetic.display_round(v bigint) returns bigint
language sql immutable parallel safe set search_path = '' as $$
  select case when v is null or v < 10000 then v
              else (v / (10 ^ (floor(log(v::numeric)) - 2))::bigint) * (10 ^ (floor(log(v::numeric)) - 2))::bigint end
$$;

create table if not exists synthetic.youtube_video_daily (
  snapshot_date date not null,
  video_id      text not null,
  views         integer not null,
  likes         integer,              -- null when the creator hides likes (as in the real data)
  comments      integer,
  primary key (snapshot_date, video_id)
);

create table if not exists synthetic.youtube_channel_daily (
  snapshot_date date primary key,
  subscribers   integer not null,
  total_views   bigint  not null,
  video_count   integer not null
);

create table if not exists synthetic.tiktok_video_daily (
  snapshot_date date not null,
  video_id      text not null,
  views         integer not null,
  likes         integer,
  comments      integer,
  shares        integer,
  saves         integer,
  primary key (snapshot_date, video_id)
);

create table if not exists synthetic.tiktok_account_daily (
  snapshot_date date primary key,
  followers     integer not null,
  hearts        bigint  not null,
  video_count   integer not null
);

create table if not exists synthetic.generation_log (
  generated_at timestamptz not null default now(),
  seed         text not null,
  details      jsonb not null
);

-- Same protection as raw: RLS on, no policies, so only the database owner / service role can read.
alter table synthetic.youtube_video_daily   enable row level security;
alter table synthetic.youtube_channel_daily enable row level security;
alter table synthetic.tiktok_video_daily    enable row level security;
alter table synthetic.tiktok_account_daily  enable row level security;
alter table synthetic.generation_log        enable row level security;

create or replace function synthetic.rebuild(p_seed text default 'ndn-v1') returns jsonb
language plpgsql set search_path = '' as $$
declare
  n_days    constant int := 304;
  yt_anchor date := (select min(snapshot_date) from raw.youtube_runs);
  tt_anchor date := (select min(snapshot_date) from raw.tiktok_runs);
  result    jsonb;
begin
  if yt_anchor is null or tt_anchor is null then
    raise exception 'need at least one real YouTube and TikTok snapshot in raw';
  end if;

  if exists (select 1 from synthetic.youtube_video_daily) or exists (select 1 from synthetic.tiktok_video_daily)
     or exists (select 1 from synthetic.youtube_channel_daily) or exists (select 1 from synthetic.tiktok_account_daily) then
    raise exception 'synthetic tables already hold data; empty them first';
  end if;

  ---------------------------------------------------------------- YouTube videos
  insert into synthetic.youtube_video_daily (snapshot_date, video_id, views, likes, comments)
  with anchor as (
    select distinct on (i->>'id') i->>'id'                     as video_id,
           (i->'snippet'->>'publishedAt')::timestamptz         as uploaded_at,
           (i->'statistics'->>'viewCount')::bigint             as v0,
           (i->'statistics'->>'likeCount')::bigint             as l0,
           (i->'statistics'->>'commentCount')::bigint          as c0,
           extract(epoch from (i->'contentDetails'->>'duration')::interval) as secs
    from raw.youtube_responses r, jsonb_array_elements(r.payload->'items') i
    where r.snapshot_date = yt_anchor and r.file_name like 'videos\_%'
    order by i->>'id'
  ), params as (
    select a.*,
           extract(epoch from ((yt_anchor + time '01:00') at time zone 'UTC') - a.uploaded_at) / 86400.0 as age0,
           least(1.2, greatest(0.08, (case when a.secs <= 60 then 0.28 else 0.45 end)
                 * exp(0.35 * synthetic.nrand(p_seed || ':k:' || a.video_id)))) as k
    from anchor a
  ), days as (                                   -- window plus the anchor day itself
    select d::date as snapshot_date, (d::date + time '01:00') at time zone 'UTC' as snap_at
    from generate_series(yt_anchor - n_days, yt_anchor, interval '1 day') d
  ), ages as (
    select d.snapshot_date, p.video_id, p.v0, p.l0, p.c0, p.age0, p.k,
           extract(epoch from d.snap_at - p.uploaded_at) / 86400.0 as age
    from params p join days d on d.snap_at > p.uploaded_at
  ), gains as (                                  -- views gained in the 24 h before each snapshot, +-25% day noise
    select a.*,
           a.v0 * (power(a.age / a.age0, a.k) - power(greatest(a.age - 1, 0) / a.age0, a.k))
             * greatest(0, 1 + 0.25 * synthetic.nrand(p_seed || ':v:' || a.video_id || ':' || a.snapshot_date)) as gain
    from ages a
  ), totals as (                                 -- walk back from the real count: total = real - later gains
    select g.*, greatest(0, g.v0 - coalesce(sum(g.gain) over (partition by g.video_id order by g.snapshot_date desc
                                   rows between unbounded preceding and 1 preceding), 0)) as v
    from gains g
  )
  select snapshot_date, video_id,
         floor(v)::int,
         floor(l0 * power(v / nullif(v0, 0), 0.9))::int,
         floor(c0 * power(v / nullif(v0, 0), 0.8))::int
  from totals
  where snapshot_date < yt_anchor;

  ---------------------------------------------------------------- YouTube channel
  insert into synthetic.youtube_channel_daily (snapshot_date, subscribers, total_views, video_count)
  with ch as (
    select (r.payload->'items'->0->'statistics'->>'subscriberCount')::bigint as subs0,
           (r.payload->'items'->0->'statistics'->>'viewCount')::bigint       as views0,
           (r.payload->'items'->0->'statistics'->>'videoCount')::int         as count0
    from raw.youtube_responses r where r.snapshot_date = yt_anchor and r.file_name = 'channel'
  ), vids as (
    select i->>'id' as video_id, (i->'snippet'->>'publishedAt')::timestamptz as uploaded_at,
           (i->'statistics'->>'viewCount')::bigint as v0
    from raw.youtube_responses r, jsonb_array_elements(r.payload->'items') i
    where r.snapshot_date = yt_anchor and r.file_name like 'videos\_%'
  ), per_day as (
    select d::date as snapshot_date,
           coalesce((select sum(views) from synthetic.youtube_video_daily y where y.snapshot_date = d::date), 0) as views_now,
           (select count(*) from vids where vids.uploaded_at >= (d::date + time '01:00') at time zone 'UTC') as not_yet_uploaded
    from generate_series(yt_anchor - n_days, yt_anchor - 1, interval '1 day') d
  )
  select p.snapshot_date,
         synthetic.display_round(floor(ch.subs0 - (ch.views0 - tv.total) * ch.subs0::numeric / ch.views0)::bigint)::int,
         tv.total,
         ch.count0 - p.not_yet_uploaded
  from per_day p cross join ch
  cross join lateral (select ch.views0 - (select sum(v0) from vids) + p.views_now as total) tv;

  ---------------------------------------------------------------- TikTok videos
  insert into synthetic.tiktok_video_daily (snapshot_date, video_id, views, likes, comments, shares, saves)
  with anchor as (
    select distinct on (e->>'id') e->>'id' as video_id,
           to_timestamp((e->>'timestamp')::bigint)   as uploaded_at,
           (e->>'view_count')::bigint    as v0,
           (e->>'like_count')::bigint    as l0,
           (e->>'comment_count')::bigint as c0,
           (e->>'repost_count')::bigint  as s0,
           (e->>'save_count')::bigint    as k0
    from raw.tiktok_responses r, jsonb_array_elements(r.payload->'entries') e
    where r.snapshot_date = tt_anchor and r.file_name = 'videos' and e->>'timestamp' is not null
    order by e->>'id'
  ), params as (
    select a.*,
           extract(epoch from ((tt_anchor + time '01:00') at time zone 'UTC') - a.uploaded_at) / 86400.0 as age0,
           4 * exp(0.5 * synthetic.nrand(p_seed || ':tt-tau:' || a.video_id)) as tau,
           0.05 + 0.15 * synthetic.urand(p_seed || ':tt-tail:' || a.video_id) as w
    from anchor a
  ), days as (
    select d::date as snapshot_date, (d::date + time '01:00') at time zone 'UTC' as snap_at
    from generate_series(tt_anchor - n_days, tt_anchor, interval '1 day') d
  ), ages as (
    select d.snapshot_date, p.video_id, p.v0, p.l0, p.c0, p.s0, p.k0, p.age0, p.tau, p.w,
           extract(epoch from d.snap_at - p.uploaded_at) / 86400.0 as age
    from params p join days d on d.snap_at > p.uploaded_at
  ), gains as (                                  -- TikTok days are burstier: +-35% day noise
    select a.*,
           a.v0 * ( ((1 - a.w) * (1 - exp(-least(a.age / a.tau, 50))) + a.w * sqrt(a.age / a.age0))
                  - ((1 - a.w) * (1 - exp(-least(greatest(a.age - 1, 0) / a.tau, 50))) + a.w * sqrt(greatest(a.age - 1, 0) / a.age0)) )
                / ((1 - a.w) * (1 - exp(-least(a.age0 / a.tau, 50))) + a.w)
             * greatest(0, 1 + 0.35 * synthetic.nrand(p_seed || ':tv:' || a.video_id || ':' || a.snapshot_date)) as gain
    from ages a
  ), totals as (
    select g.*, greatest(0, g.v0 - coalesce(sum(g.gain) over (partition by g.video_id order by g.snapshot_date desc
                                   rows between unbounded preceding and 1 preceding), 0)) as v
    from gains g
  )
  select snapshot_date, video_id,
         synthetic.display_round(floor(v)::bigint)::int,
         synthetic.display_round(floor(l0 * power(v / nullif(v0, 0), 0.9))::bigint)::int,
         synthetic.display_round(floor(c0 * power(v / nullif(v0, 0), 0.8))::bigint)::int,
         synthetic.display_round(floor(s0 * power(v / nullif(v0, 0), 0.9))::bigint)::int,
         synthetic.display_round(floor(k0 * power(v / nullif(v0, 0), 0.9))::bigint)::int
  from totals
  where snapshot_date < tt_anchor;

  ---------------------------------------------------------------- TikTok account
  insert into synthetic.tiktok_account_daily (snapshot_date, followers, hearts, video_count)
  with acct as (
    select (r.payload->'userInfo'->'statsV2'->>'followerCount')::bigint as followers0,
           (r.payload->'userInfo'->'statsV2'->>'heartCount')::bigint    as hearts0,
           (r.payload->'userInfo'->'statsV2'->>'videoCount')::int       as count0
    from raw.tiktok_responses r where r.snapshot_date = tt_anchor and r.file_name = 'profile'
  ), vids as (
    select to_timestamp((e->>'timestamp')::bigint) as uploaded_at,
           (e->>'view_count')::bigint as v0, (e->>'like_count')::bigint as l0
    from raw.tiktok_responses r, jsonb_array_elements(r.payload->'entries') e
    where r.snapshot_date = tt_anchor and r.file_name = 'videos' and e->>'timestamp' is not null
  ), totals as (select sum(v0) as v_all, sum(l0) as l_all from vids),
  per_day as (
    select d::date as snapshot_date,
           coalesce(sum(t.views), 0) as views_now, coalesce(sum(t.likes), 0) as likes_now
    from generate_series(tt_anchor - n_days, tt_anchor - 1, interval '1 day') d
    left join synthetic.tiktok_video_daily t on t.snapshot_date = d::date
    group by d::date
  )
  select p.snapshot_date,
         floor(a.followers0 - (t.v_all - p.views_now) * a.followers0::numeric / t.v_all)::int,
         a.hearts0 - (t.l_all - p.likes_now),
         a.count0 - (select count(*) from vids where vids.uploaded_at >= (p.snapshot_date + time '01:00') at time zone 'UTC')
  from per_day p cross join acct a cross join totals t;

  ---------------------------------------------------------------- log
  result := jsonb_build_object(
    'seed', p_seed,
    'youtube_window', jsonb_build_array(yt_anchor - n_days, yt_anchor - 1),
    'tiktok_window',  jsonb_build_array(tt_anchor - n_days, tt_anchor - 1),
    'youtube_video_rows', (select count(*) from synthetic.youtube_video_daily),
    'tiktok_video_rows',  (select count(*) from synthetic.tiktok_video_daily),
    'youtube_channel_rows', (select count(*) from synthetic.youtube_channel_daily),
    'tiktok_account_rows',  (select count(*) from synthetic.tiktok_account_daily));
  insert into synthetic.generation_log (seed, details) values (p_seed, result);
  return result;
end;
$$;
