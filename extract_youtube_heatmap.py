"""YouTube "Most replayed" graph for NDN's long videos (YOUTUBE_QUESTIONS.md Q3).

Why this runs on the home server: the graph is not in the YouTube Data API. yt-dlp reads it from
the public watch page (field `heatmap`), which works from a home IP; datacenter IPs (GitHub,
Supabase) often get "Sign in to confirm you're not a bot". Tested 2026-10-20 from Vic's PC and
the home server.

How it works (Extract here, Load + Transform in Supabase):
  1. Ask the youtube-extras Edge Function which videos are due (?part=heatmap_todo): never fetched,
     no graph yet (refetched weekly), or under 60 days old (the graph still changes).
  2. yt-dlp each one (no download), about one video every 3 seconds.
  3. Post [start_sec, value] pairs to ?part=heatmap_save in batches; log the run (?part=run).

Needs yt-dlp (the server uses ~/ndn_tiktok/.venv) plus SUPABASE_URL and NDN_CRON_SECRET
(environment or a .env file next to this script).

  ~/ndn_tiktok/.venv/bin/python extract_youtube_heatmap.py --by server
  py extract_youtube_heatmap.py --limit 5            # quick test from the PC
"""
import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

import yt_dlp

SAVE_BATCH = 25
PAUSE = 2.0          # seconds between videos, to stay polite
RETRY_WAIT = 300     # failed videos get one more try after this pause. In the first run (2026-10-20)
                     # all 85 errors were YouTube throttling ("Video unavailable" or "rate-limited");
                     # the same videos worked the next day


def load_env():
    env_file = Path(__file__).with_name(".env")
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    missing = [k for k in ("SUPABASE_URL", "NDN_CRON_SECRET") if not os.environ.get(k)]
    if missing:
        sys.exit(f"missing {', '.join(missing)} (environment or .env)")


def call(method, query, body=None):
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/functions/v1/youtube-extras?" + query
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "x-cron-secret": os.environ["NDN_CRON_SECRET"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def fetch(ydl, video_id):
    info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)
    points = [[round(p["start_time"], 2), round(p["value"], 4)] for p in (info.get("heatmap") or [])]
    return {"video_id": video_id, "found": bool(points), "duration_sec": info.get("duration"),
            "points": points or None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--by", default="manual")
    ap.add_argument("--limit", type=int, default=1000)
    args = ap.parse_args()
    load_env()

    todo = call("GET", f"part=heatmap_todo&limit={args.limit}")["items"]
    print(f"{len(todo)} videos due")
    rows, stats = [], {"due": len(todo), "found": 0, "no_graph": 0, "errors": 0, "retried": 0}
    opts = {"quiet": True, "no_warnings": True, "skip_download": True}
    started = time.time()
    with yt_dlp.YoutubeDL(opts) as ydl:
        ids, failed = [item["video_id"] for item in todo], []
        for attempt in (1, 2):
            if attempt == 2:
                if not failed or stats["found"] == 0:
                    break
                print(f"{len(failed)} failed; waiting {RETRY_WAIT} s, then one more try")
                time.sleep(RETRY_WAIT)
                ids, failed, stats["retried"] = failed, [], len(failed)
            for n, video_id in enumerate(ids, 1):
                try:
                    row = fetch(ydl, video_id)
                    rows.append(row)
                    stats["found" if row["found"] else "no_graph"] += 1
                except Exception as e:                   # one bad video must not stop the run
                    failed.append(video_id)
                    print(f"  {video_id}: {str(e)[:120]}")
                    if len(failed) >= 10 and stats["found"] == 0:
                        print("10 errors and no graphs: YouTube is probably blocking this IP; stopping")
                        break
                if len(rows) >= SAVE_BATCH:
                    call("POST", "part=heatmap_save", {"rows": rows})
                    rows = []
                    print(f"  {n}/{len(ids)} saved")
                time.sleep(PAUSE * attempt)              # slower on the retry
    if rows:
        call("POST", "part=heatmap_save", {"rows": rows})
    stats["errors"] = len(failed)
    stats["minutes"] = round((time.time() - started) / 60, 1)
    status = "ok" if stats["errors"] < max(5, stats["due"] // 10) else "failed"
    call("POST", f"part=run&by={args.by}", {"status": status, "detail": stats})
    print(status, stats)


if __name__ == "__main__":
    main()
