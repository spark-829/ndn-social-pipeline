"""Deezer catalog for every artist NDN has posted (data set "trends + artist catalogs", Q16).

Why this runs on the home server and not in Supabase: Deezer filters its catalog by the
caller's country. From Supabase's servers (Seoul) Lola Amour has 3 releases; from a
Philippine IP it has 33 (checked 2026-10-20). The server in Baguio has a PH IP.

How it works (Extract here, Load + Transform in Supabase):
  1. Ask the music-weekly Edge Function what to fetch next (?part=deezer_todo):
     search names -> song checks -> release lists -> track lists, one step at a time.
  2. Call Deezer for each item (free, no key; about 8 requests a second, Deezer allows 50 per 5 s).
  3. Post the replies untouched to ?part=deezer_save; the staging views do the matching.
  4. Repeat until the function says "done", then log a summary in raw.music_runs.

Standard library only, so it runs with the server's python3. Needs SUPABASE_URL and
NDN_CRON_SECRET (environment or a .env file next to this script).

  python3 extract_music_catalog.py --by server
  python3 extract_music_catalog.py --since 2026-10-20T00:30:00+08:00   # refetch rows older than that
"""
import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DEEZER = "https://api.deezer.com"
PER_SECOND = 8
WORKERS = 6
SAVE_BATCH = 50
MAX_PAGES = 5          # release lists: 100 per page, 500 is plenty


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


class RateLimit:
    def __init__(self, per_second):
        self.gap = 1.0 / per_second
        self.next = time.monotonic()
        self.lock = threading.Lock()

    def wait(self):
        with self.lock:
            now = time.monotonic()
            delay = self.next - now
            self.next = max(now, self.next) + self.gap
        if delay > 0:
            time.sleep(delay)


limit = RateLimit(PER_SECOND)
counter = {"requests": 0}


def http_json(url, data=None, headers=None, timeout=60):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def deezer(path):
    """One Deezer GET. Deezer puts errors inside a 200 reply; code 4 = slow down, 800 = no data."""
    for attempt in range(1, 6):
        limit.wait()
        counter["requests"] += 1
        try:
            body = http_json(DEEZER + path, headers={"User-Agent": "ndn-portfolio-pipeline/1.0"})
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            body = {"error": {"code": -1, "message": str(e)}}
        err = body.get("error") if isinstance(body, dict) else None
        if not err:
            return body
        if err.get("code") == 800:
            return {"data": []}
        time.sleep(attempt * 2.5)
    raise RuntimeError(f"Deezer kept failing for {path}: {err}")


def fetch_item(step, item):
    if step == "albums":                      # follow "next" so the list is complete
        data, path = [], item["path"]
        for _ in range(MAX_PAGES):
            page = deezer(path)
            data.extend(page.get("data", []))
            nxt = page.get("next")
            if not nxt:
                break
            path = nxt.replace(DEEZER, "")
        payload = {"data": data}
    else:
        payload = deezer(item["path"])
    row = {"key": item["key"], "payload": payload}
    if "query" in item:
        row["query"] = item["query"]
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--by", default="manual", help="who runs it, stored in raw.music_runs")
    ap.add_argument("--since", help="refetch rows fetched before this ISO time")
    ap.add_argument("--max-requests", type=int, default=30000, help="safety stop")
    args = ap.parse_args()
    load_env()

    fn = os.environ["SUPABASE_URL"].rstrip("/") + "/functions/v1/music-weekly"
    headers = {"x-cron-secret": os.environ["NDN_CRON_SECRET"], "Content-Type": "application/json"}
    todo_url = f"{fn}?part=deezer_todo&by={args.by}" + (f"&since={urllib.parse.quote(args.since)}" if args.since else "")
    save_url = f"{fn}?part=deezer_save&by={args.by}"

    def save(body):
        return http_json(save_url, json.dumps(body).encode("utf-8"), headers, timeout=150)

    started, saved, status, error, last = time.time(), {}, "ok", None, None
    try:
        while True:
            todo = http_json(todo_url, headers=headers, timeout=150)
            step, items = todo["step"], todo["items"]
            if step == "done":
                break
            first = (step, items[0]["key"])
            if first == last:                 # same work handed out twice: saving isn't sticking
                raise RuntimeError(f"step {step} returned the same items again ({first[1]})")
            last = first
            print(f"{time.strftime('%H:%M:%S')} {step}: {len(items)} items", flush=True)
            with ThreadPoolExecutor(WORKERS) as pool:
                rows = list(pool.map(lambda it: fetch_item(step, it), items))
            for i in range(0, len(rows), SAVE_BATCH):
                save({"step": step, "rows": rows[i:i + SAVE_BATCH]})
            saved[step] = saved.get(step, 0) + len(rows)
            if counter["requests"] >= args.max_requests:
                raise RuntimeError(f"stopped at --max-requests {args.max_requests}")
    except Exception as e:                    # log the failure, then exit non-zero
        status, error = "failed", str(e)[:500]
    detail = {"saved": saved, "requests": counter["requests"], "minutes": round((time.time() - started) / 60, 1),
              "since": args.since, "error": error}
    save({"step": "run", "status": status, "detail": detail})
    print(json.dumps({"status": status, **detail}), flush=True)
    sys.exit(0 if status == "ok" else 1)


if __name__ == "__main__":
    main()
