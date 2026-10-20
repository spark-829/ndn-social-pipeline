"""Benchmark accounts on TikTok (data set 6, sql/020_benchmarks.sql). Unofficial, like extract_tiktok.py.
Asks the `benchmarks` Edge Function which handles to fetch and posts the results back.

  --daily   account totals (followers, hearts, video count) from each profile page
            GitHub daily.yml, after the NDN snapshot
  --weekly  counts for the latest 50 videos of each account (yt-dlp flat listing)
            GitHub weekly.yml, Mondays

Profile pages: plain request first (works from GitHub), headless browser if that fails
(Vic's home IP gets blocked on plain requests; needs playwright + chromium).

    py extract_benchmarks_tiktok.py --daily
    py extract_benchmarks_tiktok.py --weekly
Needs SUPABASE_URL and NDN_CRON_SECRET (.env or environment).
"""
import argparse, logging, os, sys
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv

import extract_tiktok

LATEST = 50
log = logging.getLogger("extract_benchmarks_tiktok")


def profile_stats(handle, browser_holder):
    try:
        if browser_holder:                              # plain requests already failed this run
            raise RuntimeError("using the browser")
        info = extract_tiktok.fetch_profile(handle)["payload"]["userInfo"]
    except RuntimeError as err:
        log.warning("%s: plain request failed (%s), trying the browser", handle, err)
        if not browser_holder:
            from extract_tiktok_extras import Browser
            browser_holder.append(Browser())
        info = browser_holder[0].profile({"handle": handle})["payload"]
    s = info.get("statsV2") or info.get("stats") or {}     # statsV2 = exact counts
    return {"followers": s.get("followerCount"), "hearts": s.get("heartCount"), "videos": s.get("videoCount")}


def latest_videos(handle):
    import yt_dlp
    from yt_dlp.networking.impersonate import ImpersonateTarget
    opts = {"extract_flat": True, "skip_download": True, "quiet": True, "no_warnings": True,
            "playlistend": LATEST, "impersonate": ImpersonateTarget.from_str("chrome")}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.tiktok.com/@{handle}", download=False)
    out = []
    for e in (info.get("entries") or [])[:LATEST]:
        if not e.get("id") or e.get("timestamp") is None:
            continue
        out.append({"id": str(e["id"]), "title": e.get("title") or e.get("description"),
                    "url": e.get("url") or f"https://www.tiktok.com/@{handle}/video/{e['id']}",
                    "published_at": datetime.fromtimestamp(e["timestamp"], timezone.utc).isoformat(),
                    "views": e.get("view_count"), "likes": e.get("like_count"), "comments": e.get("comment_count")})
    if not out:
        raise RuntimeError("yt-dlp returned no videos")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--daily", action="store_true")
    mode.add_argument("--weekly", action="store_true")
    ap.add_argument("--by", default="manual")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    load_dotenv()
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/functions/v1/benchmarks"
    headers = {"x-cron-secret": os.environ["NDN_CRON_SECRET"].strip()}

    accounts = requests.get(url, params={"step": "tiktok"}, headers=headers, timeout=60).json()["items"]
    rows, failed, browser = [], [], []
    for a in accounts:
        try:
            if args.daily:
                rows.append({"account_key": a["account_key"], **profile_stats(a["handle"], browser)})
            else:
                rows.append({"account_key": a["account_key"], "videos": latest_videos(a["handle"])})
            log.info("%s: ok", a["handle"])
        except Exception as err:                       # one account failing shouldn't stop the others
            failed.append(a["handle"])
            log.error("%s: %s", a["handle"], err)
    if browser:
        browser[0].close()

    step = "tiktok_daily" if args.daily else "tiktok_weekly"
    r = requests.post(url, params={"step": step, "by": args.by}, json={"rows": rows}, headers=headers, timeout=150)
    print(r.status_code, r.text[:500])
    return 0 if r.ok and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
