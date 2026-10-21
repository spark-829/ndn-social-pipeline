"""TikTok extras, weekly (sql/014_tiktok_extras.sql). Extract here, Load through the tiktok-extras
Edge Function (asks it what to fetch, posts the results back). Unofficial, like extract_tiktok.py.

Steps (each only for what is new or due):
  pages     each video's page via yt-dlp's own page reader: sound (music id, original or not),
            real repost count, tagged place, @mentions, TikTok's suggested search words
  sounds    each sound's page in a headless browser: how many videos use it (Q12)
  comments  top-level comments through TikTok's web comment list (plain request, Chrome TLS)
  profiles  artists' own accounts (auto-found from @mentions, or listed by Vic) and benchmark
            accounts, in a headless browser
  artist_videos  each artist account's latest 30 videos with their sound, via yt-dlp's account
            listing (sql/026); also tries artists' Instagram usernames as TikTok handles
  artist_sounds  "videos using this sound" for the artists' own released songs found above

Where it works (tested 2026-10-20): all four from Vic's PC (home IP), where plain profile
requests are blocked. GitHub Actions runs it weekly (.github/workflows/weekly.yml).

    py extract_tiktok_extras.py                      # all steps
    py extract_tiktok_extras.py --steps comments --limit 50
    py extract_tiktok_extras.py --steps artist_videos,artist_sounds
Needs SUPABASE_URL and NDN_CRON_SECRET (.env or environment). Also: playwright + chromium.
"""
import argparse, json, logging, os, re, sys, time

import requests
from dotenv import load_dotenv

STEPS = ["pages", "sounds", "comments", "profiles", "artist_videos", "artist_sounds"]
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
EMBED_RE = re.compile(r'<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>', re.S)
DROP_FROM_PAGE = ("video", "author", "desc", "imagePost")   # links that expire + caption we already have
COMMENT_FIELDS = ("cid", "text", "create_time", "digg_count", "reply_comment_total", "author_pin", "is_author_digged")
MUSIC_FIELDS = ("id", "title", "authorName", "original", "album", "duration")
ARTIST_LATEST = 30
SOUND_UNAVAILABLE = 202001   # music/detail statusCode for a sound that is gone or not shown here (checked 2026-10-22)
SAVE_EVERY = 25
MAX_FAILS = 25          # per step: stop the step if TikTok keeps refusing

log = logging.getLogger("extract_tiktok_extras")


class Feed:
    def __init__(self, base_url, secret, by):
        self.url = base_url.rstrip("/") + "/functions/v1/tiktok-extras"
        self.headers = {"x-cron-secret": secret}
        self.by = by

    def todo(self, step, limit):
        r = requests.get(self.url, params={"step": step, "limit": limit, "by": self.by}, headers=self.headers, timeout=120)
        r.raise_for_status()
        return r.json()["items"]

    def save(self, step, rows):
        if rows:
            r = requests.post(self.url, params={"step": step, "by": self.by}, json={"rows": rows}, headers=self.headers, timeout=150)
            r.raise_for_status()

    def log_run(self, status, detail):
        requests.post(self.url, params={"step": "run", "by": self.by}, json={"status": status, "detail": detail},
                      headers=self.headers, timeout=60)


# ---------------------------------------------------------------- fetchers
class Pages:
    def __init__(self):
        import yt_dlp
        from yt_dlp.networking.impersonate import ImpersonateTarget
        self.ydl = yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True,
                                     "impersonate": ImpersonateTarget.from_str("chrome")})
        self.ie = self.ydl.get_info_extractor("TikTok")

    def fetch(self, item):
        vid = item["video_id"]
        data, status = self.ie._extract_web_data_and_status(f"https://www.tiktok.com/@ninedegreesnorth/video/{vid}", vid)
        if status != 0 or not data.get("id"):
            raise RuntimeError(f"status {status}")
        item_out = {k: v for k, v in data.items() if k not in DROP_FROM_PAGE}
        if data.get("imagePost"):
            item_out["imagePostCount"] = len(data["imagePost"].get("images", []))
        music = dict(item_out.get("music") or {})
        for k in [k for k in music if k.endswith(("Url", "Large", "Medium", "Thumb"))]:
            music.pop(k)                                   # cover/play links expire
        item_out["music"] = music
        return {"video_id": vid, "item": item_out}

    def close(self):
        self.ydl.close()


class ArtistVideos:
    """An account's latest videos with their sound, from yt-dlp's account listing (the headless-browser
    profile page gets an empty video list). yt-dlp keeps the song title but drops the sound id, so its
    parser is wrapped to keep the music fields."""
    def __init__(self):
        import yt_dlp
        from yt_dlp.extractor import tiktok as tt
        from yt_dlp.networking.impersonate import ImpersonateTarget
        if not getattr(tt.TikTokBaseIE, "_ndn_keeps_music", False):
            parse = tt.TikTokBaseIE._parse_aweme_video_web

            def keep_music(ie, aweme, *args, **kwargs):
                out = parse(ie, aweme, *args, **kwargs)
                out["ndn_music"] = {k: (aweme.get("music") or {}).get(k) for k in MUSIC_FIELDS}
                return out
            tt.TikTokBaseIE._parse_aweme_video_web = keep_music
            tt.TikTokBaseIE._ndn_keeps_music = True
        self.ydl = yt_dlp.YoutubeDL({"extract_flat": True, "skip_download": True, "quiet": True, "no_warnings": True,
                                     "playlistend": ARTIST_LATEST, "impersonate": ImpersonateTarget.from_str("chrome")})

    def fetch(self, item):
        h = item["handle"]
        try:
            info = self.ydl.extract_info(f"https://www.tiktok.com/@{h}", download=False)
        except Exception as e:
            # a guessed handle that doesn't exist: saved as not found (tried again after 30 days)
            if item.get("guess_for") and "secondary user ID" in str(e):
                return {"handle": h, "guess_for": item["guess_for"], "found": False, "videos": []}
            raise
        entries = list(info.get("entries") or [])
        return {"handle": h, "guess_for": item.get("guess_for"), "found": True,
                "nickname": next((e["channel"] for e in entries if e.get("channel")), None),
                "videos": [{"video_id": e["id"], "posted_at": e.get("timestamp"), "views": e.get("view_count"),
                            "music": e.get("ndn_music")} for e in entries if e.get("id")]}

    def close(self):
        self.ydl.close()


class Browser:
    """One headless Chromium for sound pages and profiles."""
    def __init__(self):
        from playwright.sync_api import sync_playwright
        self.pw = sync_playwright().start()
        self.browser = self.pw.chromium.launch(headless=True)
        self.page = self.browser.new_context(locale="en-US", user_agent=UA).new_page()

    def sound(self, item):
        mid = item["music_id"]
        with self.page.expect_response(lambda r: "/api/music/detail" in r.url, timeout=25000) as resp:
            self.page.goto(f"https://www.tiktok.com/music/x-{mid}", wait_until="domcontentloaded", timeout=60000)
        reply = resp.value.json()
        if reply.get("statusCode") == SOUND_UNAVAILABLE:  # TikTok's "sound not available" (removed or region-locked)
            return {"music_id": mid, "payload": {"statusCode": SOUND_UNAVAILABLE}}   # saved without a count: skipped this week
        info = reply.get("musicInfo") or {}
        if not info.get("stats"):
            raise RuntimeError(f"no stats in reply (statusCode {reply.get('statusCode')})")
        return {"music_id": mid, "payload": info}

    def profile(self, item):
        h = item["handle"]
        self.page.goto(f"https://www.tiktok.com/@{h}", wait_until="load", timeout=60000)
        self.page.wait_for_timeout(2500)
        m = EMBED_RE.search(self.page.content())
        detail = json.loads(m.group(1))["__DEFAULT_SCOPE__"].get("webapp.user-detail", {}) if m else {}
        if detail.get("statusCode") != 0 or not detail.get("userInfo"):
            raise RuntimeError(f"profile status {detail.get('statusCode')}")
        return {"handle": h, "payload": detail["userInfo"]}

    def close(self):
        self.browser.close()
        self.pw.stop()


class Comments:
    def __init__(self):
        from curl_cffi import requests as cr
        self.s = cr.Session(impersonate="chrome")

    def fetch(self, item):
        vid, out, cursor = item["video_id"], [], 0
        for _ in range(200):                               # 200 pages x 50 = 10,000 comments max
            r = self.s.get("https://www.tiktok.com/api/comment/list/",
                           params={"aid": 1988, "aweme_id": vid, "count": 50, "cursor": cursor}, timeout=30)
            d = r.json() if r.status_code == 200 and r.text else {}
            if d.get("status_code", 0) != 0:
                raise RuntimeError(f"status {d.get('status_code')}")
            for c in d.get("comments") or []:
                row = {k: c.get(k) for k in COMMENT_FIELDS}
                row["user"] = {k: (c.get("user") or {}).get(k) for k in ("unique_id", "nickname")}
                out.append(row)
            if not d.get("has_more") or not d.get("comments"):
                break
            cursor = d.get("cursor", cursor + 50)
            time.sleep(0.5)
        if item["expected"] and not out:
            raise RuntimeError("no comments returned")
        return {"video_id": vid, "expected": item["expected"], "comments": out}


# ---------------------------------------------------------------- runner
def run_step(feed, step, fetch, limit, pause):
    done = fails = 0
    tried = set()
    while limit is None or done < limit:
        items = [i for i in feed.todo(step, 200) if json.dumps(i, sort_keys=True) not in tried]
        if not items:
            break
        batch = []
        for item in items:
            if limit is not None and done >= limit:
                break
            tried.add(json.dumps(item, sort_keys=True))
            try:
                batch.append(fetch(item))
                done += 1
            except Exception as e:                         # skip it this run; it stays on the to-do list
                fails += 1
                log.warning("%s %s: %s", step, next(iter(item.values())), str(e)[:150])
                if fails >= MAX_FAILS:
                    feed.save(step, batch)
                    raise RuntimeError(f"{step}: {fails} failures, TikTok may be blocking this IP")
            if len(batch) >= SAVE_EVERY:
                feed.save(step, batch)
                batch = []
            time.sleep(pause)
        feed.save(step, batch)
        log.info("%s: %d saved, %d failed so far", step, done, fails)
    return {"saved": done, "failed": fails}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", default=",".join(STEPS))
    ap.add_argument("--limit", type=int, help="max items per step (testing)")
    ap.add_argument("--by", default="manual")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    load_dotenv()
    url, secret = os.environ.get("SUPABASE_URL"), os.environ.get("NDN_CRON_SECRET")
    if not url or not secret:
        sys.exit("SUPABASE_URL and NDN_CRON_SECRET are needed (.env or environment)")
    feed = Feed(url, secret, args.by)

    started, results, status = time.time(), {}, "ok"
    steps = [s for s in STEPS if s in args.steps.split(",")]
    browser = Browser() if {"sounds", "profiles", "artist_sounds"} & set(steps) else None
    try:
        for step in steps:
            try:
                if step == "pages":
                    p = Pages()
                    try:
                        results[step] = run_step(feed, step, p.fetch, args.limit, 1.0)
                    finally:
                        p.close()
                elif step == "sounds":
                    results[step] = run_step(feed, step, browser.sound, args.limit, 1.0)
                elif step == "comments":
                    results[step] = run_step(feed, step, Comments().fetch, args.limit, 0.5)
                elif step == "profiles":
                    results[step] = run_step(feed, step, browser.profile, args.limit, 1.0)
                elif step == "artist_videos":
                    a = ArtistVideos()
                    try:
                        results[step] = run_step(feed, step, a.fetch, args.limit, 1.0)
                    finally:
                        a.close()
                elif step == "artist_sounds":
                    results[step] = run_step(feed, step, browser.sound, args.limit, 1.0)
            except Exception as e:                         # one step failing doesn't stop the others
                status = "partial"
                results[step] = {"error": str(e)[:300]}
                log.error("%s failed: %s", step, e)
    finally:
        if browser:
            browser.close()
    detail = {"steps": results, "minutes": round((time.time() - started) / 60, 1)}
    feed.log_run(status, detail)
    print(json.dumps({"status": status, **detail}))
    return 0 if status == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
