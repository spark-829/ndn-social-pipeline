"""
STEP 6 of the NDN pipeline: EXTRACT (TikTok), then send the snapshot to Supabase.

TikTok has no free public API for someone else's account, so this SCRAPES
public pages (unofficial; may break when TikTok changes its site):

  1. Profile page  tiktok.com/@ninedegreesnorth -> followers, likes, video count
     (read from the JSON TikTok embeds in the page, __UNIVERSAL_DATA_FOR_REHYDRATION__)
  2. yt-dlp (open source) -> every video with views, likes, comments, shares, saves

Caveat: TikTok itself rounds counts >= 10,000 to 3 digits (9.9M, 15.6K).

Saved untouched in data/raw/tiktok/<UTC date>/ (profile.json, videos.json, _SUCCESS.json).
Only change: yt-dlp's thumbnail URLs and request headers are dropped (signed links
that expire within days; they doubled the file size).

Run:
    py extract_tiktok.py              # today's snapshot (local only)
    py extract_tiktok.py --upload     # ...and send it to Supabase (needs SUPABASE_URL + NDN_CRON_SECRET)
    py extract_tiktok.py --force      # redo today's snapshot
"""
import argparse, json, logging, os, re, sys, time
from datetime import datetime, timezone
from pathlib import Path

import requests
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
RAW_ROOT = BASE_DIR / "data" / "raw" / "tiktok"

NDN_USERNAME = "ninedegreesnorth"
MIN_COVERAGE = 0.9          # fail if yt-dlp returns < 90% of the profile's video count
MAX_RETRIES = 3
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/141.0 Safari/537.36")
EMBED_RE = re.compile(r'<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>', re.S)

log = logging.getLogger("extract_tiktok")


def fetch_profile(username: str, session=requests) -> dict:
    """Profile page -> the embedded 'webapp.user-detail' JSON, untouched."""
    url = f"https://www.tiktok.com/@{username}"
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = session.get(url, headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"}, timeout=30)
            m = EMBED_RE.search(resp.text) if resp.status_code == 200 else None
            if m:
                detail = json.loads(m.group(1))["__DEFAULT_SCOPE__"].get("webapp.user-detail", {})
                if detail.get("statusCode") == 0 and detail.get("userInfo"):
                    return {"url": url, "payload": detail}
            reason = f"HTTP {resp.status_code}, embedded data {'found' if m else 'missing'}"
        except requests.RequestException as err:
            reason = str(err)
        if attempt == MAX_RETRIES:
            raise RuntimeError(f"profile page unusable ({reason}); TikTok may be blocking this IP")
        log.warning("profile: %s - retry %d/%d", reason, attempt, MAX_RETRIES)
        time.sleep(5 * attempt)


def fetch_videos(username: str, ydl_factory=None) -> dict:
    """yt-dlp flat listing of every video on the profile (metadata only, no downloads)."""
    opts = {"extract_flat": True, "skip_download": True, "quiet": True, "no_warnings": True}
    if ydl_factory is None:
        import yt_dlp
        from yt_dlp.networking.impersonate import ImpersonateTarget
        ydl_factory = yt_dlp.YoutubeDL
        # Send Chrome's TLS fingerprint (needs curl_cffi). From GitHub's IPs TikTok returns an
        # empty video list to Python's default fingerprint; with this it worked 4/4 (2026-10-13).
        opts["impersonate"] = ImpersonateTarget.from_str("chrome")
    url = f"https://www.tiktok.com/@{username}"
    with ydl_factory(opts) as ydl:
        info = ydl.sanitize_info(ydl.extract_info(url, download=False))
    for e in info.get("entries") or []:
        e.pop("thumbnails", None)
        e.pop("http_headers", None)
    info.pop("__files_to_move", None)
    return {"url": url, "payload": info}


def save_raw(folder: Path, name: str, result: dict, stamp: str, tool: str) -> dict:
    record = {"_meta": {"source": tool, "extracted_at_utc": stamp, "request_url": result["url"]},
              "response": result["payload"]}
    (folder / f"{name}.json").write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
    return record


def run(username: str, folder: Path, session=requests, ydl_factory=None) -> dict:
    folder.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")

    profile = fetch_profile(username, session)
    stats = profile["payload"]["userInfo"]["stats"]

    videos = fetch_videos(username, ydl_factory)
    n = len(videos["payload"].get("entries") or [])
    expected = int(stats.get("videoCount") or 0)
    if expected and n < MIN_COVERAGE * expected:      # partial scrape: don't save a misleading day
        raise RuntimeError(f"yt-dlp returned {n} videos but the profile shows {expected}")

    try:
        import yt_dlp
        ytdlp_version = yt_dlp.version.__version__
    except Exception:
        ytdlp_version = "unknown"
    save_raw(folder, "profile", profile, stamp, "tiktok.com profile page (embedded JSON)")
    save_raw(folder, "videos", videos, stamp, f"yt-dlp {ytdlp_version}")

    summary = {"extracted_at_utc": stamp, "username": username, "videos": n,
               "followers": stats.get("followerCount"), "profile_video_count": expected,
               "ytdlp_version": ytdlp_version}
    (folder / "_SUCCESS.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def upload(folder: Path, supabase_url: str, secret: str, triggered_by: str, session=requests) -> dict:
    """POST the day's files to the tiktok-ingest Edge Function, which writes raw.tiktok_*."""
    body = {"snapshot_date": folder.name,
            "summary": json.loads((folder / "_SUCCESS.json").read_text(encoding="utf-8")),
            "files": {name: json.loads((folder / f"{name}.json").read_text(encoding="utf-8"))
                      for name in ("profile", "videos")}}
    resp = session.post(f"{supabase_url.rstrip('/')}/functions/v1/tiktok-ingest?by={triggered_by}",
                        json=body, headers={"x-cron-secret": secret}, timeout=120)
    if resp.status_code != 200:
        raise RuntimeError(f"ingest: HTTP {resp.status_code}: {resp.text[:300]}")
    return resp.json()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Daily TikTok snapshot for Nine Degrees North.")
    ap.add_argument("--user", default=NDN_USERNAME)
    ap.add_argument("--force", action="store_true", help="redo today's snapshot")
    ap.add_argument("--upload", action="store_true", help="send the snapshot to Supabase")
    ap.add_argument("--by", default="manual", help="who triggered it (manual, github)")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv(BASE_DIR / ".env")

    folder = RAW_ROOT / datetime.now(timezone.utc).date().isoformat()
    try:
        if (folder / "_SUCCESS.json").exists() and not args.force:
            log.info("Today's snapshot already exists (%s).", folder.name)
        else:
            s = run(args.user, folder)
            log.info("Extracted. videos=%d followers=%s -> %s", s["videos"], s["followers"], folder)
        if args.upload:
            url, secret = os.getenv("SUPABASE_URL", "").strip(), os.getenv("NDN_CRON_SECRET", "").strip()
            if not url or not secret:
                log.error("SUPABASE_URL and NDN_CRON_SECRET are needed for --upload.")
                return 1
            log.info("Uploaded: %s", upload(folder, url, secret, args.by))
    except Exception as err:
        log.error("FAILED: %s", err)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
