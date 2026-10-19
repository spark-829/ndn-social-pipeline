-- 008: what the Tableau dashboard reads, in one place.
--   mart.tableau_dim_video     dim_video + real "per day" measures (was a query in export_tableau.py)
--   mart.tableau_song_compare  one row per song across platforms (Q3)
--   mart.insight_facts         one JSON row of today's numbers; the Claude routine writes text ONLY from these
--   mart.insights              the dashboard sentences, one row per slot per day (written by the Claude routine)
-- Used by export_tableau.py (CSV) and the tableau-feed Edge Function (Google Sheets bridge).

create or replace view mart.tableau_dim_video as
with v as (
    select *, greatest(1, latest_snapshot - published_date_ph) as age_days
    from mart.dim_video),
p as (
    select *, round(latest_views::numeric / age_days, 2) as views_per_day,
              round(latest_likes::numeric / age_days, 2) as likes_per_day,
              round(coalesce(latest_views, latest_likes)::numeric / age_days, 2) as perf_per_day   -- Instagram: likes
    from v),
m as (
    select platform, series, percentile_cont(0.5) within group (order by perf_per_day) as series_median
    from p group by platform, series)
select p.platform, video_id, title, url, published_at, published_date_ph, published_weekday_ph,
       published_weekday_num, published_hour_ph, duration_sec, format, p.series, session, song, artist,
       song_key, mentions_cozy_cove, latest_views, latest_likes, latest_comments, latest_snapshot,
       age_days, views_per_day, likes_per_day, perf_per_day,
       round((latest_likes + coalesce(latest_comments, 0))::numeric / nullif(latest_views, 0), 4) as engagement_rate,
       round(perf_per_day / nullif(m.series_median, 0)::numeric, 2) as vs_series_median
from p join m on m.platform = p.platform and m.series is not distinct from p.series;

create or replace view mart.tableau_song_compare as
select song_key, min(song) as song, min(artist) as artist,
       sum(latest_views) filter (where platform = 'YouTube')   as youtube_views,
       sum(latest_views) filter (where platform = 'TikTok')    as tiktok_views,
       sum(latest_likes) filter (where platform = 'Instagram') as instagram_likes,
       count(*) filter (where platform = 'YouTube')   as youtube_videos,
       count(*) filter (where platform = 'TikTok')    as tiktok_videos,
       count(*) filter (where platform = 'Instagram') as instagram_posts,
       bool_or(series = 'Live at The Cozy Cove')      as is_cozy_cove
from mart.dim_video
where song is not null and song_key is not null and song_key <> '|'
group by song_key;

create table if not exists mart.insights (
    as_of       date        not null,
    slot        text        not null,     -- summary_headline, action_1..3, audience_headline, sessions_headline, upload_headline
    sort_order  int         not null,
    text        text        not null,
    written_by  text        not null default 'claude-routine',
    created_at  timestamptz not null default now(),
    primary key (as_of, slot)
);

create or replace view mart.insight_facts as
with v as (select * from mart.tableau_dim_video),
yt_full as (select * from v where platform = 'YouTube' and format = 'Full video'),
wd as (select published_weekday_ph as day, count(*) as n,
              round(percentile_cont(0.5) within group (order by views_per_day)::numeric) as median_views_per_day
       from yt_full group by 1),
acc as (select platform, snapshot_date, followers, data_source from mart.fact_account_daily),
latest as (select distinct on (platform) platform, snapshot_date, followers from acc order by platform, snapshot_date desc),
growth as (select platform, min(snapshot_date) as since, max(snapshot_date) as until,
                  max(followers) - min(followers) as gained
           from acc where data_source = 'real' group by platform),
songs as (select * from mart.tableau_song_compare where youtube_views > 0 and tiktok_views > 0),
fresh as (select song, artist, platform, published_date_ph, views_per_day
          from v where platform = 'YouTube' and series = 'Live at The Cozy Cove'
            and published_date_ph >= (select max(latest_snapshot) from v) - 30
          order by views_per_day desc nulls last limit 3)
select (select max(latest_snapshot) from v) as as_of,
       jsonb_build_object(
         'followers', (select jsonb_object_agg(platform, followers) from latest),
         'followers_total', (select sum(followers) from latest),
         'real_growth', (select jsonb_object_agg(platform, jsonb_build_object('since', since, 'until', until,
                          'gained', gained)) from growth),
         'youtube_views_total', (select sum(latest_views) from v where platform = 'YouTube'),
         'cozy_cove_share_pct', (select round(100.0 * sum(latest_views) filter (where series = 'Live at The Cozy Cove')
                                  / sum(latest_views)) from v where platform = 'YouTube'),
         'median_views_per_day', (select jsonb_object_agg(format, med) from (
                                  select format, round(percentile_cont(0.5) within group (order by views_per_day)::numeric) med
                                  from v where platform = 'YouTube' group by format) x),
         'engagement_pct', (select jsonb_object_agg(format, eng) from (
                            select format, round(100 * avg(engagement_rate), 2) eng
                            from v where platform in ('YouTube', 'TikTok') group by format) x),
         'weekday_median_views_per_day', (select jsonb_object_agg(day, jsonb_build_object('n', n,
                                          'median', median_views_per_day)) from wd),
         'pct_uploads_at_7pm', (select round(100.0 * count(*) filter (where published_hour_ph = 19) / count(*))
                                from yt_full),
         'youtube_tiktok', (select jsonb_build_object('songs', count(*), 'r_log', round(corr(ln(youtube_views),
                            ln(tiktok_views))::numeric, 2), 'tiktok_bigger', count(*) filter (where tiktok_views >
                            youtube_views)) from songs),
         'cozy_cove_last_30_days_top', (select jsonb_agg(fresh) from fresh)
       ) as facts;
