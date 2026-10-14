-- 004d_synthetic_batched.sql
-- Same SYNTHETIC model as 004_synthetic_backfill.sql, split into small batches.
-- Why: building ~500k rows in one statement ran out of memory on the free tier (the database restarted,
-- 2026-10-14). Each call below handles about a tenth of one platform's videos (~30k rows), stays far under
-- the 2-minute query limit, and needs no background job.
--
-- Run order (seed 'ndn-v1', 10 buckets):
--   select synthetic.build_youtube('ndn-v1', b, 10);  for b = 0..9
--   select synthetic.build_tiktok('ndn-v1', b, 10);   for b = 0..9
--   select synthetic.build_accounts('ndn-v1');        channel / account totals, writes generation_log
-- A video belongs to bucket mod(abs(hashtext(video_id)), 10). Each bucket refuses to run twice.

create or replace function synthetic.build_youtube(p_seed text, p_bucket int, p_buckets int) returns int
language plpgsql set search_path = '' as $$
declare
  n_days    constant int := 304;
  yt_anchor date := (select min(snapshot_date) from raw.youtube_runs);
  n         int;
begin
  if exists (select 1 from synthetic.youtube_video_daily y
             where mod(abs(hashtext(y.video_id)), p_buckets) = p_bucket) then
    raise exception 'youtube bucket % already built', p_bucket;
  end if;

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
      and mod(abs(hashtext(i->>'id')), p_buckets) = p_bucket
    order by i->>'id'
  ), params as (
    select a.*,
           extract(epoch from ((yt_anchor + time '01:00') at time zone 'UTC') - a.uploaded_at) / 86400.0 as age0,
           least(1.2, greatest(0.08, (case when a.secs <= 60 then 0.28 else 0.45 end)
                 * exp(0.35 * synthetic.nrand(p_seed || ':k:' || a.video_id)))) as k
    from anchor a
  ), days as (
    select d::date as snapshot_date, (d::date + time '01:00') at time zone 'UTC' as snap_at
    from generate_series(yt_anchor - n_days, yt_anchor, interval '1 day') d
  ), ages as (
    select d.snapshot_date, p.video_id, p.v0, p.l0, p.c0, p.age0, p.k,
           extract(epoch from d.snap_at - p.uploaded_at) / 86400.0 as age
    from params p join days d on d.snap_at > p.uploaded_at
  ), gains as (                     -- views gained in the 24 h before each snapshot, +-25% day noise
    select a.*,
           a.v0 * (power(a.age / a.age0, a.k) - power(greatest(a.age - 1, 0) / a.age0, a.k))
             * greatest(0, 1 + 0.25 * synthetic.nrand(p_seed || ':v:' || a.video_id || ':' || a.snapshot_date)) as gain
    from ages a
  ), totals as (                    -- walk back from the real count: total = real - all later gains
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

  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function synthetic.build_tiktok(p_seed text, p_bucket int, p_buckets int) returns int
language plpgsql set search_path = '' as $$
declare
  n_days    constant int := 304;
  tt_anchor date := (select min(snapshot_date) from raw.tiktok_runs);
  n         int;
begin
  if exists (select 1 from synthetic.tiktok_video_daily t
             where mod(abs(hashtext(t.video_id)), p_buckets) = p_bucket) then
    raise exception 'tiktok bucket % already built', p_bucket;
  end if;

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
      and mod(abs(hashtext(e->>'id')), p_buckets) = p_bucket
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
  ), gains as (                     -- TikTok days are burstier: +-35% day noise; exp clamped (underflow)
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

  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function synthetic.build_accounts(p_seed text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  n_days    constant int := 304;
  yt_anchor date := (select min(snapshot_date) from raw.youtube_runs);
  tt_anchor date := (select min(snapshot_date) from raw.tiktok_runs);
  result    jsonb;
begin
  if exists (select 1 from synthetic.youtube_channel_daily) or exists (select 1 from synthetic.tiktok_account_daily) then
    raise exception 'account tables already built';
  end if;

  insert into synthetic.youtube_channel_daily (snapshot_date, subscribers, total_views, video_count)
  with ch as (
    select (r.payload->'items'->0->'statistics'->>'subscriberCount')::bigint as subs0,
           (r.payload->'items'->0->'statistics'->>'viewCount')::bigint       as views0,
           (r.payload->'items'->0->'statistics'->>'videoCount')::int         as count0
    from raw.youtube_responses r where r.snapshot_date = yt_anchor and r.file_name = 'channel'
  ), vids as (
    select distinct on (i->>'id') i->>'id' as video_id, (i->'snippet'->>'publishedAt')::timestamptz as uploaded_at,
           (i->'statistics'->>'viewCount')::bigint as v0
    from raw.youtube_responses r, jsonb_array_elements(r.payload->'items') i
    where r.snapshot_date = yt_anchor and r.file_name like 'videos\_%'
    order by i->>'id'
  ), daily as (
    select snapshot_date, sum(views) as views_now from synthetic.youtube_video_daily group by snapshot_date
  ), per_day as (
    select d::date as snapshot_date, coalesce(dl.views_now, 0) as views_now,
           (select count(*) from vids where vids.uploaded_at >= (d::date + time '01:00') at time zone 'UTC') as not_yet_uploaded
    from generate_series(yt_anchor - n_days, yt_anchor - 1, interval '1 day') d
    left join daily dl on dl.snapshot_date = d::date
  )
  select p.snapshot_date,
         synthetic.display_round(floor(ch.subs0 - (ch.views0 - tv.total) * ch.subs0::numeric / ch.views0)::bigint)::int,
         tv.total,
         ch.count0 - p.not_yet_uploaded
  from per_day p cross join ch
  cross join lateral (select ch.views0 - (select sum(v0) from vids) + p.views_now as total) tv;

  insert into synthetic.tiktok_account_daily (snapshot_date, followers, hearts, video_count)
  with acct as (
    select (r.payload->'userInfo'->'statsV2'->>'followerCount')::bigint as followers0,
           (r.payload->'userInfo'->'statsV2'->>'heartCount')::bigint    as hearts0,
           (r.payload->'userInfo'->'statsV2'->>'videoCount')::int       as count0
    from raw.tiktok_responses r where r.snapshot_date = tt_anchor and r.file_name = 'profile'
  ), vids as (
    select distinct on (e->>'id') to_timestamp((e->>'timestamp')::bigint) as uploaded_at,
           (e->>'view_count')::bigint as v0, (e->>'like_count')::bigint as l0
    from raw.tiktok_responses r, jsonb_array_elements(r.payload->'entries') e
    where r.snapshot_date = tt_anchor and r.file_name = 'videos' and e->>'timestamp' is not null
    order by e->>'id'
  ), totals as (select sum(v0) as v_all, sum(l0) as l_all from vids),
  daily as (
    select snapshot_date, sum(views) as views_now, sum(likes) as likes_now
    from synthetic.tiktok_video_daily group by snapshot_date
  ), per_day as (
    select d::date as snapshot_date, coalesce(dl.views_now, 0) as views_now, coalesce(dl.likes_now, 0) as likes_now
    from generate_series(tt_anchor - n_days, tt_anchor - 1, interval '1 day') d
    left join daily dl on dl.snapshot_date = d::date
  )
  select p.snapshot_date,
         floor(a.followers0 - (t.v_all - p.views_now) * a.followers0::numeric / t.v_all)::int,
         a.hearts0 - (t.l_all - p.likes_now),
         a.count0 - (select count(*) from vids where vids.uploaded_at >= (p.snapshot_date + time '01:00') at time zone 'UTC')
  from per_day p cross join acct a cross join totals t;

  result := jsonb_build_object(
    'seed', p_seed, 'method', 'batched (004d)',
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
