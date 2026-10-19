"""Export the mart views from Supabase to CSV files for Tableau Public.

Tableau Public cannot connect to a database, only to files (or Google Sheets), so this script downloads
the star schema built in sql/005_staging_mart.sql:

    tableau/dim_video.csv           one row per video (platform, title, song, artist, series, upload time ...)
    tableau/fact_video_daily.csv    one row per video per day (views, gains, data_source real/synthetic)
    tableau/fact_account_daily.csv  one row per platform per day (followers/subscribers, totals)
    tableau/song_compare.csv        one row per song: YouTube vs TikTok vs Instagram (real latest counts)
    tableau/tiktok_video.csv        one row per TikTok video: performance index, rates, caption type, sound (v2)
    tableau/tiktok_hashtag.csv      hashtags on 10+ videos (v2)
    tableau/platform_scorecard.csv  one row per platform: followers, 7-day change, best post (v2)

dim_video also gets real "per day" measures (latest counts / days since upload) so old and new videos compare
fairly without the synthetic history: age_days, views_per_day, likes_per_day, engagement_rate, vs_series_median.

Needs SUPABASE_DB_URL in .env: Supabase dashboard -> Connect -> "Session pooler" URI, with your database
password filled in. Never paste it in chat or commit it (.env is gitignored).

Usage:  py export_tableau.py
"""
import csv
import os
import re
import sys
import time
from pathlib import Path

import psycopg
from dotenv import load_dotenv

BASE = Path(__file__).resolve().parent
OUT = BASE / "tableau"

EXPORTS = {
    # per-day measures live in the view (sql/008_dashboard_feed.sql), shared with the tableau-feed Edge Function
    "dim_video": "select * from mart.tableau_dim_video order by platform, published_at",
    "fact_video_daily": """
        select platform, video_id, snapshot_date, data_source, views, likes, comments, shares, saves,
               views_gained, likes_gained, days_since_upload
        from mart.fact_video_daily order by platform, video_id, snapshot_date""",
    "fact_account_daily": """
        select platform, snapshot_date, data_source, followers, followers_gained, total_views, views_gained,
               video_count, hearts
        from mart.fact_account_daily order by platform, snapshot_date""",
    # Q3: the same song on each platform (song_key = normalised song|artist); sums if a song has several videos
    "song_compare": "select * from mart.tableau_song_compare order by youtube_views desc nulls last",
    # dashboard sentences written daily by the Claude routine "NDN dashboard insights" (latest day only)
    "insights": """select as_of, slot, sort_order, text, written_by from mart.insights
                   where as_of = (select max(as_of) from mart.insights) order by sort_order""",
    # dashboard v2 (sql/012_dashboard_v2.sql): same column lists as the tableau-feed Edge Function
    "tiktok_video": """select video_id, url, left(regexp_replace(caption, '[[:space:]]+', ' ', 'g'), 300) as caption, published_at::text, published_date_ph::text, weekday_ph,
                 weekday_num, hour_ph, time_window, posts_that_day, duration_sec, length_group, views, likes, comments,
                 shares, saves, latest_snapshot::text, age_days, case when is_mature then 'yes' else 'no' end as is_mature,
                 case when is_last_30d then 'yes' else 'no' end as is_last_30d, likes_per_1k, comments_per_1k,
                 shares_per_1k, saves_per_1k, share_save_per_1k, share_save_group, neighbour_median, perf_index,
                 index_band, views_gained_7d, gained_since::text, caption_type,
                 case when asks_question then 'yes' else 'no' end as asks_question, n_hashtags, hashtag_group, track,
                 sound_type, song, artist, series
          from mart.tableau_tiktok_video order by published_at""",
    "tiktok_hashtag": "select hashtag, videos, median_index, breakout_pct, median_views from mart.tableau_tiktok_hashtag order by videos desc",
    "platform_scorecard": """select platform, as_of::text, window_start::text, window_days, metric_name, followers, followers_change,
                 followers_change_pct, metric_gained, posts_in_window, left(regexp_replace(best_post, '[[:space:]]+', ' ', 'g'), 120) as best_post, best_post_url,
                 best_post_gained
          from mart.tableau_platform_scorecard order by followers desc""",
}


def redact(text: str) -> str:
    """Hide the password in any connection string that ends up in an error message."""
    return re.sub(r"(postgres(?:ql)?://[^:/@]+:)[^@]+@", r"\1***@", str(text))


def export(conn: psycopg.Connection, name: str, query: str) -> tuple[int, int]:
    path = OUT / f"{name}.csv"
    tmp = path.with_suffix(".csv.part")            # write to a temp file so a failed run never leaves half a CSV
    copy_sql = f"copy ({query}) to stdout with (format csv, header true, encoding 'UTF8')"
    with conn.cursor() as cur, open(tmp, "wb") as f:
        with cur.copy(copy_sql) as copy:
            for chunk in copy:
                f.write(chunk)
    tmp.replace(path)
    with open(path, newline="", encoding="utf-8") as f:   # csv module: captions can contain line breaks
        rows = sum(1 for _ in csv.reader(f)) - 1           # minus the header
    return rows, path.stat().st_size


def main() -> int:
    load_dotenv(BASE / ".env")
    url = os.getenv("SUPABASE_DB_URL", "").strip()
    if not url:
        print("SUPABASE_DB_URL is missing in .env (Supabase -> Connect -> Session pooler URI).", file=sys.stderr)
        return 2
    OUT.mkdir(exist_ok=True)
    try:
        with psycopg.connect(url, connect_timeout=20) as conn:
            conn.execute("set statement_timeout = 0")
            for name, query in EXPORTS.items():
                t0 = time.time()
                rows, size = export(conn, name, query)
                print(f"{name:20} {rows:>9,} rows  {size / 1e6:6.1f} MB  {time.time() - t0:5.1f} s")
    except psycopg.Error as e:
        print("export failed:", redact(e), file=sys.stderr)
        return 1
    print(f"done -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
