"""Export the dashboard tables from Supabase to CSV files for the Power BI report (offline test mode).

Power BI Desktop could read Supabase directly, but for testing we load plain CSV files first, so the report works
with no database login. Later the same queries move into the model as PostgreSQL sources.

    powerbi/data/<table>.csv     one file per table below (UTF-8, header row)
    powerbi/data/_schema.json    column names + Postgres types, read by build_powerbi.py to type the columns

Booleans are exported as 'yes' / 'no' text and timestamps in Philippine time, so Power BI needs no time-zone logic.

Needs SUPABASE_DB_URL in .env (same as export_tableau.py). Usage:  py export_powerbi.py
"""
import json
import os
import sys
import time
from pathlib import Path

import psycopg
from dotenv import load_dotenv

from export_tableau import redact

BASE = Path(__file__).resolve().parent
OUT = BASE / "powerbi" / "data"


def clean(col: str, n: int) -> str:
    """Text column with line breaks and runs of spaces collapsed, cut to n characters."""
    return f"left(regexp_replace({col}, '[[:space:]]+', ' ', 'g'), {n})"


# age at the latest snapshot, in bands (prefix numbers keep the bands in order on an axis)
AGE_BAND = ("case when {age} < 30 then '1 Under 30 days' when {age} < 90 then '2 1-3 months' "
            "when {age} < 365 then '3 3-12 months' when {age} < 730 then '4 1-2 years' else '5 Over 2 years' end")

# best post title without the series tag, so the Overview table fits without scrolling
SHORT_POST = r"regexp_replace(best_post, '\s*\(Live at The Cozy Cove\)', '', 'i')"

EXPORTS = {
    # one row per video, all platforms (sql/008 tableau_dim_video: real per-day measures)
    "dim_video": f"""
        with gain as (   -- views / likes gained in the last 7 real days (Q8 / Q10: which old posts keep earning)
          select platform, video_id, sum(views_gained) as views_gained_7d, sum(likes_gained) as likes_gained_7d
          from mart.fact_video_daily
          where data_source = 'real'
            and snapshot_date > (select max(snapshot_date) from mart.fact_video_daily where data_source = 'real') - 7
          group by 1, 2
        ), listeners as (   -- artist size: the biggest Spotify monthly listeners among the video's artists
          select va.platform, va.video_id, max(s.monthly_listeners) as artist_monthly_listeners
          from staging.video_artist va
          join staging.spotify_artist_snapshot s using (spotify_id)
          where s.snapshot_date = (select max(snapshot_date) from staging.spotify_artist_snapshot)
          group by 1, 2
        ), song as (   -- Spotify streams of the studio version of the session's song (YouTube Q5)
          select video_id, max(studio_streams_latest) as song_spotify_streams
          from staging.youtube_session_spotify group by 1
        )
        select v.platform, v.video_id, {clean('v.title', 160)} as title, v.url,
               (v.published_at at time zone 'Asia/Manila')::timestamp as published_ph, v.published_date_ph,
               v.published_weekday_ph, v.published_weekday_num, v.published_hour_ph,
               case when v.published_hour_ph = 19 then '7 pm' else 'Other times' end as upload_slot,
               v.duration_sec, v.format as video_format, v.series, v.song, v.artist,
               v.latest_views, v.latest_likes, v.latest_comments, v.latest_snapshot, v.age_days,
               {AGE_BAND.format(age='v.age_days')} as age_band,
               v.views_per_day, v.likes_per_day, v.perf_per_day, v.engagement_rate, v.vs_series_median,
               g.views_gained_7d, g.likes_gained_7d, l.artist_monthly_listeners, s.song_spotify_streams,
               i.caption_type as ig_caption_type, i.hashtag_count as ig_hashtags, i.reposts as ig_reposts,
               round(1000.0 * i.reposts / nullif(i.views, 0), 2) as reposts_per_1k_views,
               round(1000.0 * v.latest_comments / nullif(v.latest_likes, 0), 1) as comments_per_1k_likes,
               case when i.hashtag_count is null then null when i.hashtag_count = 0 then '0 tags'
                    when i.hashtag_count <= 3 then '1-3 tags' when i.hashtag_count <= 5 then '4-5 tags'
                    else '6+ tags' end as ig_hashtag_group
        from mart.tableau_dim_video v
        left join gain g using (platform, video_id)
        left join listeners l using (platform, video_id)
        left join song s on v.platform = 'YouTube' and s.video_id = v.video_id
        left join staging.instagram_post_latest i on v.platform = 'Instagram' and i.post_id = v.video_id""",
    # one row per platform per day; data_source = real or synthetic (labelled backfill)
    "account_daily": """
        select platform, snapshot_date, data_source, followers, followers_gained, total_views, views_gained,
               video_count, hearts
        from mart.fact_account_daily""",
    # views/likes gained per platform per day (sum over videos), small instead of the 36 MB per-video file
    "platform_daily": """
        select platform, snapshot_date, data_source, sum(views_gained) as views_gained,
               sum(likes_gained) as likes_gained, count(*) as videos
        from mart.fact_video_daily group by 1, 2, 3""",
    # one row per platform: followers, change over the window, best post (sql/012)
    "scorecard": f"""
        select platform, as_of, window_days, metric_name, followers, followers_change, followers_change_pct,
               metric_gained, posts_in_window,
               case when length({SHORT_POST}) > 48 then {clean(SHORT_POST, 46)} || '…' else {SHORT_POST} end as best_post,
               best_post_url,
               best_post_gained
        from mart.tableau_platform_scorecard""",
    # one row per TikTok video: performance index and the post's habits (sql/012)
    "tiktok_video": f"""
        select t.video_id, t.url, {clean('t.caption', 90)} as caption, t.published_date_ph,
               date_trunc('month', t.published_date_ph)::date as published_month,
               extract(year from t.published_date_ph)::int::text as published_year, t.weekday_ph, t.weekday_num,
               t.hour_ph, t.time_window,
               case when t.posts_that_day >= 4 then '4+' else t.posts_that_day::text end as posts_that_day,
               t.duration_sec, t.length_group, t.views, t.likes, t.comments, t.shares, t.saves,
               t.age_days, {AGE_BAND.format(age='t.age_days')} as age_band,
               case when t.is_mature then 'yes' else 'no' end as is_mature,
               case when t.is_last_30d then 'yes' else 'no' end as is_last_30d,
               t.likes_per_1k, t.comments_per_1k, t.shares_per_1k, t.saves_per_1k,
               t.shares_per_1k + t.saves_per_1k as share_save_per_1k, t.neighbour_median, t.perf_index, t.index_band,
               t.views_gained_7d, round(1000.0 * t.views_gained_7d / nullif(t.views, 0), 2) as gained_7d_per_1k,
               t.caption_type, case when t.asks_question then 'yes' else 'no' end as asks_question, t.n_hashtags,
               t.hashtag_group, t.sound_type, t.song, t.artist, t.series,
               case when ss.sound_author = 'Nine Degrees North' then ss.videos_using_sound end as sound_uses
        from mart.tableau_tiktok_video t
        left join staging.tiktok_video_page p using (video_id)
        left join staging.tiktok_sound_stats ss on ss.music_id = p.music_id
          and ss.snapshot_date = (select max(snapshot_date) from staging.tiktok_sound_stats)""",
    "tiktok_hashtag": "select hashtag, videos, median_index, breakout_pct, median_views from mart.tableau_tiktok_hashtag",
    # today's sentences from the Claude routine (15:00 PH), latest day only
    "insights": """select as_of, slot, sort_order, text as sentence from mart.insights
                   where as_of = (select max(as_of) from mart.insights)""",
    # fan requests in YouTube + TikTok comments (sql/023)
    "fan_demand": """
        select artist, case when not_in_list then 'Never on NDN' else 'Played for NDN' end as status, fans,
               invite_fans, more_fans, youtube_asks, tiktok_asks, fans_per_1000_comments, latest_ask,
               last_ndn_post, case when cooling_down then 'yes' else 'no' end as cooling_down
        from mart.fan_demand_artist""",
    "fan_upload": f"""
        select artist, fans, asks, asks_for_streaming, latest_ask, {clean('top_ask', 140)} as top_ask
        from mart.fan_upload_request""",
    # who to invite to Live at The Cozy Cove: score (TikTok first), its parts and the raw numbers behind it (sql/026)
    "invite": """
        select case when count(*) over (partition by artist) > 1 then artist || ' (' || left(spotify_id, 4) || ')'
                    else artist end as artist,
               status, hit_status, ndn_history, found_via, case when best_chart_rank is null then 'no' else 'yes' end as on_chart,
               status_rank, score, tiktok_points, spotify_points, other_points,
               tt_song_videos, tt_song_growth, tt_follower_growth, track_record, new_hit_hype, momentum, local_reach,
               fan_demand, size,
               new_hit, new_hit_found_on, new_hit_tiktok_videos, new_hit_tiktok_growth_4w, new_hit_daily_streams,
               new_hit_released, top_song, top_song_daily_streams,
               case when top_song_on_ndn then 'yes' else 'no' end as top_song_on_ndn, top_tiktok_song, top_tiktok_song_videos,
               monthly_listeners, spotify_followers, followers_per_listener, ph_listeners, manila_baguio_listeners,
               best_chart_rank, weeks_on_chart, tiktok_handle, tiktok_found_by, tiktok_followers,
               tiktok_follower_growth_4w, fans_asking, tiktok_asks,
               ndn_youtube_videos, ndn_tiktok_clips, ndn_tiktok_index, ndn_youtube_index, latest_visit, last_ndn_post,
               cooldown_until, new_hit_tiktok_added_7d, tt_song_basis, new_hit_top30_rank, new_hit_top30_points,
               new_hit_top50_pos, new_hit_viral_pos, new_hit_billboard_pos,
               case when new_hit_on_ndn then 'yes' else 'no' end as new_hit_on_ndn, action,
               ndn_video_title, ndn_video_link, ndn_video_views
        from mart.invite_candidates""",
    # the OPM top 30 of Top 50 PH + Viral Hits PH + Billboard PH Hot 100, with TikTok videos per song (sql/029)
    "invite_top30": """
        select rank, song, artist, points, top50_pos, viral_pos, billboard_pos, tiktok_videos, videos_added_7d,
               growth_4w, sounds_kept, fan_sounds_kept, sounds_unchecked, top_sound, top_sound_link, to_do, counted_on,
               case when on_ndn then 'yes' else 'no' end as on_ndn, invite_group
        from mart.invite_top30_tiktok""",
    # YouTube Q3: where in the session viewers replay most (yt-dlp "most replayed", weekly)
    "yt_heatmap": """
        select h.video_id, v.title, v.artist, h.duration_sec, h.peak_sec,
               round(100.0 * h.peak_sec / h.duration_sec) as peak_pct,
               lpad((least(9, floor(10.0 * h.peak_sec / h.duration_sec)::int) * 10)::text, 2, '0') || '-'
                 || (least(9, floor(10.0 * h.peak_sec / h.duration_sec)::int) * 10 + 10)::text || '%' as peak_band,
               h.peak_ratio
        from (select distinct on (video_id) * from staging.youtube_heatmap_peak
              where duration_sec > 0 order by video_id, snapshot_date desc) h
        join mart.tableau_dim_video v on v.platform = 'YouTube' and v.video_id = h.video_id""",
    # YouTube Q7: where NDN's session ranks when someone searches the song (90 searches, Mondays)
    "yt_search": """
        select query, reason, target_rank, ndn_best_rank, first_channel,
               case when ndn_best_rank = 1 then '1 First' when ndn_best_rank <= 3 then '2 Top 3'
                    when ndn_best_rank <= 10 then '3 4-10' else '4 Below 10 or missing' end as rank_band
        from staging.youtube_search_rank
        where snapshot_date = (select max(snapshot_date) from staging.youtube_search_rank)""",
    # YouTube Q11: PH Trending Music today
    "yt_trending": f"""
        select rank, {clean('title', 90)} as title, channel_title, views,
               case when is_ndn then 'yes' else 'no' end as is_ndn
        from staging.youtube_trending_ph
        where snapshot_date = (select max(snapshot_date) from staging.youtube_trending_ph)""",
    # Instagram Q6: the same song on each platform (real latest counts)
    "song_compare": """
        select song, artist, youtube_views, tiktok_views, instagram_likes
        from mart.tableau_song_compare where youtube_views is not null and instagram_likes is not null""",
    # one row per benchmark account, so a Region filter reaches both benchmark tables
    "dim_account": """
        select name as account, region from raw.benchmark_accounts where active
        union select 'Nine Degrees North', 'ndn'""",
    # latest followers per account and platform, NDN included (sql/021)
    "bench_accounts": """
        select account_key, name as account, region, platform, followers, total_views, total_likes, posts
        from mart.benchmark_growth where snapshot_date = (select max(snapshot_date) from mart.benchmark_growth)""",
    # uploads of the last 12 months (older than 14 days so fresh uploads don't drag the median), views today
    "bench_uploads": """
        with latest as (
          select distinct on (platform, video_id) platform, video_id, views
          from raw.benchmark_video_weekly order by platform, video_id, snapshot_date desc
        ), uploads as (
          select a.name, a.region, v.platform, l.views
          from raw.benchmark_video v
          join latest l using (platform, video_id)
          join raw.benchmark_accounts a using (account_key)
          where a.active and a.account_key <> 'ndn'
            and v.published_at >= now() - interval '12 months' and v.published_at < now() - interval '14 days'
          union all
          select 'Nine Degrees North', 'ndn', platform, latest_views
          from mart.tableau_dim_video
          where published_at >= now() - interval '12 months' and published_at < now() - interval '14 days'
        )
        select name as account, region, platform, count(*) as uploads_12m, round(count(*) / 12.0, 1) as uploads_per_month,
               round(percentile_cont(0.5) within group (order by views)::numeric) as median_views
        from uploads where views is not null group by 1, 2, 3""",
}


def export(conn: psycopg.Connection, name: str, query: str) -> tuple[int, list]:
    """Write one query to CSV and return (rows, [[column, postgres type], ...])."""
    with conn.cursor() as cur:
        cur.execute(f"select * from ({query}) q limit 0")
        cols = [[d.name, conn.adapters.types.get(d.type_code).name] for d in cur.description]
    path = OUT / f"{name}.csv"
    tmp = path.with_suffix(".csv.part")            # temp file, so a failed run never leaves half a CSV
    rows = 0
    with conn.cursor() as cur, open(tmp, "wb") as f:
        with cur.copy(f"copy ({query}) to stdout with (format csv, header true, encoding 'UTF8')") as copy:
            for chunk in copy:
                f.write(chunk)
        rows = cur.rowcount
    tmp.replace(path)
    return rows, cols


def main() -> int:
    load_dotenv(BASE / ".env")
    url = os.getenv("SUPABASE_DB_URL", "").strip()
    if not url:
        print("SUPABASE_DB_URL is missing in .env (Supabase -> Connect -> Session pooler URI).", file=sys.stderr)
        return 2
    OUT.mkdir(parents=True, exist_ok=True)
    schema = {}
    try:
        with psycopg.connect(url, connect_timeout=20) as conn:
            conn.execute("set statement_timeout = 0")
            for name, query in EXPORTS.items():
                t0 = time.time()
                rows, schema[name] = export(conn, name, query)
                print(f"{name:16} {rows:>7,} rows  {time.time() - t0:5.1f} s")
    except psycopg.Error as e:
        print("export failed:", redact(e), file=sys.stderr)
        return 1
    (OUT / "_schema.json").write_text(json.dumps(schema, indent=1), encoding="utf-8")
    print(f"done -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
