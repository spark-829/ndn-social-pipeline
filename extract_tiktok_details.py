"""Per-video TikTok details for Nine Degrees North.

The profile listing (extract_tiktok.py) cuts captions off, so hashtags arrive as "#cozyc".
This script opens each video's own page once and stores, untouched:
  - the full caption
  - TikTok's auto-captions file (WebVTT) when the video has one (mostly recent videos, fil-PH)
into raw.tiktok_video_details (sql/009). staging.tiktok_video_details parses hashtags and
turns the captions file into plain transcript text.

Only videos not yet in the table are fetched, newest first, so the first run takes about an
hour (~980 videos) and later runs take seconds. Progress is saved after every video.

Where it saves: SUPABASE_DB_URL set (PC .env) -> straight into the database; otherwise
SUPABASE_URL + NDN_CRON_SECRET (GitHub Actions) -> through the tiktok-details Edge Function.

Usage:
  py extract_tiktok_details.py --limit 3     # test on the 3 newest videos
  py extract_tiktok_details.py              # everything still missing
"""
import argparse
import json
import logging
import os
import random
import sys
import time
from pathlib import Path

import psycopg
from dotenv import load_dotenv

BASE = Path(__file__).resolve().parent
VIDEO_URL = "https://www.tiktok.com/@ninedegreesnorth/video/{}"
KEEP = ("id", "description", "track", "artists", "album", "duration", "timestamp", "tags",
        "view_count", "like_count", "comment_count", "repost_count", "save_count")
log = logging.getLogger("tiktok_details")

MISSING_SQL = """
select s.video_id
from staging.tiktok_video_snapshot s
left join raw.tiktok_video_details d using (video_id)
where s.snapshot_date = (select max(snapshot_date) from staging.tiktok_video_snapshot)
  and d.video_id is null
order by s.published_at desc
"""

UPSERT_SQL = """
insert into raw.tiktok_video_details (video_id, fetched_at, description, subtitle_lang, subtitle_vtt, info)
values (%s, now(), %s, %s, %s, %s)
on conflict (video_id) do update set fetched_at = now(), description = excluded.description,
  subtitle_lang = excluded.subtitle_lang, subtitle_vtt = excluded.subtitle_vtt, info = excluded.info
"""


def make_ydl():
    import yt_dlp
    from yt_dlp.networking.impersonate import ImpersonateTarget
    # Chrome's TLS fingerprint (curl_cffi), same reason as extract_tiktok.py.
    target = ImpersonateTarget.from_str("chrome")
    # yt-dlp only looks up captions when asked to write them; download=False means nothing is written.
    opts = {"skip_download": True, "quiet": True, "no_warnings": True, "impersonate": target,
            "writesubtitles": True, "subtitleslangs": ["all"],
            "ignore_no_formats_error": True}  # photo posts have no video file but still have a caption
    return yt_dlp.YoutubeDL(opts), target


def pick_subtitle(info: dict):
    """Prefer Filipino/Tagalog, then English, then anything else that is WebVTT."""
    subs = info.get("subtitles") or {}
    order = sorted(subs, key=lambda lang: (not lang.lower().startswith(("fil", "tl")),
                                           not lang.lower().startswith("en"), lang))
    for lang in order:
        for f in subs[lang]:
            if f.get("ext") == "vtt" and f.get("url"):
                return lang, f["url"]
    return None, None


def fetch_one(ydl, target, video_id: str) -> dict:
    from yt_dlp.networking import Request
    info = ydl.extract_info(VIDEO_URL.format(video_id), download=False)
    lang, sub_url = pick_subtitle(info)
    vtt = None
    if sub_url:
        resp = ydl.urlopen(Request(sub_url, extensions={"impersonate": target}))
        vtt = resp.read().decode("utf-8", "replace")
    return {"video_id": video_id, "description": info.get("description"),
            "subtitle_lang": lang, "subtitle_vtt": vtt,
            "info": {k: info.get(k) for k in KEEP}}


class DbStore:
    """PC: straight into the database with SUPABASE_DB_URL."""
    def __init__(self, url):
        self.conn = psycopg.connect(url, connect_timeout=20)

    def missing(self):
        return [r[0] for r in self.conn.execute(MISSING_SQL).fetchall()]

    def save(self, row):
        self.conn.execute(UPSERT_SQL, (row["video_id"], row["description"], row["subtitle_lang"],
                                       row["subtitle_vtt"], json.dumps(row["info"], ensure_ascii=False)))
        self.conn.commit()

    def close(self):
        self.conn.close()


class FunctionStore:
    """GitHub Actions: through the tiktok-details Edge Function (only NDN_CRON_SECRET needed)."""
    def __init__(self, base_url, secret):
        import requests
        self.s = requests.Session()
        self.s.headers["x-cron-secret"] = secret
        self.url = base_url.rstrip("/") + "/functions/v1/tiktok-details"

    def missing(self):
        r = self.s.get(self.url, timeout=60)
        r.raise_for_status()
        return r.json()["video_ids"]

    def save(self, row):
        r = self.s.post(self.url, json={**row, "video_id": str(row["video_id"])}, timeout=60)
        r.raise_for_status()

    def close(self):
        self.s.close()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--limit", type=int, default=0, help="fetch at most N videos (0 = all missing)")
    ap.add_argument("--max-errors", type=int, default=10, help="stop after N errors in a row (likely blocked)")
    ap.add_argument("--refetch", nargs="+", metavar="VIDEO_ID", help="fetch these videos again (overwrites their rows)")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    load_dotenv(BASE / ".env")
    if os.environ.get("SUPABASE_DB_URL"):
        store = DbStore(os.environ["SUPABASE_DB_URL"])
    elif os.environ.get("SUPABASE_URL") and os.environ.get("NDN_CRON_SECRET"):
        store = FunctionStore(os.environ["SUPABASE_URL"], os.environ["NDN_CRON_SECRET"])
    else:
        log.error("set SUPABASE_DB_URL, or SUPABASE_URL + NDN_CRON_SECRET")
        return 2

    try:
        ids = args.refetch or store.missing()
        if args.limit:
            ids = ids[:args.limit]
        log.info("videos to fetch: %d", len(ids))
        ydl, target = make_ydl()
        done = with_subs = errors_in_row = failed = 0
        for i, vid in enumerate(ids, 1):
            try:
                row = fetch_one(ydl, target, vid)
            except Exception as exc:  # one bad video must not stop the run
                failed += 1
                errors_in_row += 1
                log.warning("%s failed: %s", vid, str(exc)[:200])
                if errors_in_row >= args.max_errors:
                    log.error("%d errors in a row, stopping (TikTok may be blocking). Re-run later.", errors_in_row)
                    break
                time.sleep(10)
                continue
            errors_in_row = 0
            store.save(row)
            done += 1
            with_subs += row["subtitle_vtt"] is not None
            if i % 25 == 0 or i == len(ids):
                log.info("progress %d/%d (saved %d, with captions file %d, failed %d)",
                         i, len(ids), done, with_subs, failed)
            time.sleep(random.uniform(1.5, 3.0))  # be polite
    finally:
        store.close()

    log.info("finished: saved %d, with captions file %d, failed %d", done, with_subs, failed)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
