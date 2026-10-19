-- 012 Dashboard v2 (2026-10-19): feeds for the Executive page and the TikTok questions page.
-- All three views read REAL snapshots only (staging), never the synthetic backfill.
--
--   mart.tableau_tiktok_video       one row per TikTok video, every field the TikTok questions need (Q1-Q15)
--   mart.tableau_tiktok_hashtag     one row per hashtag used on 10+ mature videos (Q15)
--   mart.tableau_platform_scorecard one row per platform: followers, 7-day change, posts, best post this week

------------------------------------------------------------------ TikTok, one row per video
create or replace view mart.tableau_tiktok_video as
with latest as (
    select distinct on (video_id) * from staging.tiktok_video_snapshot
    order by video_id, snapshot_date desc
), last_day as (
    select max(snapshot_date) d from staging.tiktok_video_snapshot
), week_start as (       -- first snapshot inside the last 7 days (tracking began 2026-10-13)
    select distinct on (s.video_id) s.video_id, s.snapshot_date, s.views
    from staging.tiktok_video_snapshot s, last_day
    where s.snapshot_date >= last_day.d - 7
    order by s.video_id, s.snapshot_date
), ordered as (
    select l.*, row_number() over (order by l.published_at, l.video_id) rn, count(*) over () n
    from latest l
), neighbours as (       -- Q14: median views of the 30 posts nearest in time (the video itself left out)
    select a.video_id,
           (select percentile_cont(0.5) within group (order by b.views)
            from ordered b
            where b.rn between greatest(1, least(a.rn - 15, a.n - 30)) and greatest(1, least(a.rn - 15, a.n - 30)) + 30
              and b.rn <> a.rn) as neighbour_median
    from ordered a
), base as (
    select l.video_id, l.url, coalesce(d.caption_full, l.caption) as caption,
           l.published_at,
           (l.published_at at time zone 'Asia/Manila')::date              as published_date_ph,
           to_char(l.published_at at time zone 'Asia/Manila', 'Dy')      as weekday_ph,
           extract(isodow from l.published_at at time zone 'Asia/Manila')::int as weekday_num,
           extract(hour from l.published_at at time zone 'Asia/Manila')::int   as hour_ph,
           l.duration_sec, l.views, l.likes, l.comments, l.shares, l.saves,
           l.snapshot_date as latest_snapshot,
           (l.snapshot_date - (l.published_at at time zone 'Asia/Manila')::date) as age_days,
           l.views - w.views as views_gained_7d, w.snapshot_date as gained_since,
           n.neighbour_median,
           d.n_hashtags, d.caption_asks_question, d.hashtags,
           rd.info->>'track' as track,
           lower(coalesce(d.caption_full, l.caption)) as c,
           dv.song, dv.artist, dv.series
    from latest l
    join neighbours n using (video_id)
    left join week_start w using (video_id)
    left join staging.tiktok_video_details d using (video_id)
    left join raw.tiktok_video_details rd using (video_id)
    left join mart.dim_video dv on dv.platform = 'TikTok' and dv.video_id = l.video_id
)
select video_id, url, caption, published_at, published_date_ph, weekday_ph, weekday_num, hour_ph,
       case when hour_ph between 5 and 11 then '1 Morning (5-11)'
            when hour_ph between 12 and 16 then '2 Afternoon (12-16)'
            when hour_ph between 17 and 21 then '3 Evening (17-21)'
            else '4 Late night (22-4)' end                                   as time_window,
       count(*) over (partition by published_date_ph)                         as posts_that_day,
       duration_sec,
       case when duration_sec < 15 then '1 Under 15 s' when duration_sec <= 30 then '2 15-30 s'
            when duration_sec <= 60 then '3 31-60 s' else '4 Over 60 s' end  as length_group,
       views, likes, comments, shares, saves, latest_snapshot, age_days,
       (age_days >= 14)                                                       as is_mature,
       (published_date_ph > latest_snapshot - 30)                             as is_last_30d,
       round(1000.0 * likes    / nullif(views, 0), 2) as likes_per_1k,
       round(1000.0 * comments / nullif(views, 0), 2) as comments_per_1k,
       round(1000.0 * shares   / nullif(views, 0), 2) as shares_per_1k,
       round(1000.0 * saves    / nullif(views, 0), 2) as saves_per_1k,
       round(1000.0 * (shares + saves) / nullif(views, 0), 2) as share_save_per_1k,
       -- Q4 groups: equal quarters of videos with 1,000+ views
       case when views >= 1000 then
            (array['1 Lowest 25%', '2 Second 25%', '3 Third 25%', '4 Top 25%'])
            [ntile(4) over (partition by views >= 1000 order by (shares + saves)::numeric / nullif(views, 0))]
       end                                                                    as share_save_group,
       round(neighbour_median::numeric)                                       as neighbour_median,
       round((views / nullif(neighbour_median, 0))::numeric, 3)               as perf_index,
       case when views / nullif(neighbour_median, 0) >= 2 then '1 Breakout (2x+)'
            when views / nullif(neighbour_median, 0) >= 1 then '2 Above typical (1-2x)'
            else '3 Below typical' end                                       as index_band,
       views_gained_7d, gained_since,
       case when c ~ 'premiere'                                                then '1 Premiere teaser'
            when c ~ '(now streaming|out now|now on youtube|out on youtube|stream )' then '2 Out now / stream'
            when c ~ '(ticket|line ?up|date reveal|venue|headlin|catch .* live)'     then '3 Event / tickets'
            when c ~ '(\(live at|cozy cove fest|performs|reimagined)'               then '4 Song clip, title caption'
            else '5 Other (talk, relatable line)' end                        as caption_type,
       coalesce(caption_asks_question, false)                                 as asks_question,
       coalesce(n_hashtags, 0)                                                as n_hashtags,
       case when coalesce(n_hashtags, 0) = 0 then '0 tags' when n_hashtags <= 3 then '1-3 tags'
            when n_hashtags <= 5 then '4-5 tags' else '6+ tags' end         as hashtag_group,
       track,
       case when track is null then 'Unknown'
            when track ~* '^(original sound|som original|sonido original|оригинальный звук)' then 'Original sound'
            else 'Named track' end                                            as sound_type,
       song, artist, series
from base;

------------------------------------------------------------------ Q15: hashtags (10+ mature videos)
create or replace view mart.tableau_tiktok_hashtag as
select '#' || ltrim(lower(tag), '#')                                    as hashtag,
       count(*)                                                         as videos,
       round(percentile_cont(0.5) within group (order by v.perf_index)::numeric, 2) as median_index,
       round(avg((v.perf_index >= 2)::int) * 100)                       as breakout_pct,
       round(percentile_cont(0.5) within group (order by v.views)::numeric) as median_views
from mart.tableau_tiktok_video v
join staging.tiktok_video_details d using (video_id)
cross join lateral unnest(d.hashtags) tag
where v.is_mature
group by 1
having count(*) >= 10;

------------------------------------------------------------------ Executive: one row per platform
-- Window = the last 7 days of real snapshots (or fewer while tracking is young; see window_start).
-- Main metric = views (YouTube, TikTok) or likes (Instagram hides views from the public API).
create or replace view mart.tableau_platform_scorecard as
with acct as (
    select 'YouTube' platform, snapshot_date, subscribers followers from staging.youtube_channel_snapshot
    union all select 'TikTok', snapshot_date, followers from staging.tiktok_account_snapshot
    union all select 'Instagram', snapshot_date, followers from staging.instagram_account_snapshot
), posts as (
    select 'YouTube' platform, snapshot_date, video_id post_id, title, 'https://www.youtube.com/watch?v=' || video_id url,
           published_at, views metric from staging.youtube_video_snapshot
    union all select 'TikTok', snapshot_date, video_id, caption, url, published_at, views from staging.tiktok_video_snapshot
    union all select 'Instagram', snapshot_date, post_id, caption, url, published_at, likes from staging.instagram_post_snapshot
), win as (
    select platform, max(snapshot_date) as_of, greatest(min(snapshot_date), max(snapshot_date) - 7) window_start
    from acct group by platform
), f as (
    select w.platform, w.as_of, w.window_start,
           max(a.followers) filter (where a.snapshot_date = w.as_of)        as followers,
           max(a.followers) filter (where a.snapshot_date = w.window_start) as followers_start
    from win w join acct a using (platform) group by 1, 2, 3
), gains as (           -- per post: metric on the last day minus the first day of the window
    select p.platform, p.post_id,
           max(p.title) title, max(p.url) url, max(p.published_at) published_at,
           max(p.metric) filter (where p.snapshot_date = w.as_of)
             - coalesce(max(p.metric) filter (where p.snapshot_date = w.window_start), 0) as gained
    from posts p join win w using (platform)
    where p.snapshot_date in (w.as_of, w.window_start)
    group by 1, 2
), best as (
    select distinct on (platform) platform, title best_post, url best_post_url, gained best_post_gained
    from gains where gained is not null order by platform, gained desc
)
select f.platform, f.as_of, f.window_start, (f.as_of - f.window_start) as window_days,
       case when f.platform = 'Instagram' then 'likes' else 'views' end as metric_name,
       f.followers, f.followers - f.followers_start as followers_change,
       round(100.0 * (f.followers - f.followers_start) / nullif(f.followers_start, 0), 2) as followers_change_pct,
       (select sum(gained) from gains g where g.platform = f.platform)                    as metric_gained,
       (select count(*) from gains g where g.platform = f.platform
          and (g.published_at at time zone 'Asia/Manila')::date > f.window_start)          as posts_in_window,
       b.best_post, b.best_post_url, b.best_post_gained
from f left join best b using (platform);
