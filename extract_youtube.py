"""
STEP 1 of the NDN pipeline: EXTRACT (YouTube).

Takes a daily snapshot of the Nine Degrees North YouTube channel using the
public YouTube Data API v3 (free API key, no channel access needed):

  1. channels.list      -> channel stats + the ID of the "uploads" playlist
  2. playlistItems.list -> every video ID on the channel (50 per page)
  3. videos.list        -> every public field for every video (50 per call)

Step 2 is only a lookup: the API has no cheap "list all videos" call, and the
uploads playlist is the one complete list of IDs (search costs 100 units and
stops at ~500 results). Its pages hold nothing that videos.list lacks, so
they are used in memory and not saved.

channel.json and videos_*.json are saved untouched in data/raw/youtube/<date>/.
Public APIs only return *current* totals, so history = one snapshot per day.

Run:
    pip install -r requirements.txt
    python extract_youtube.py              # today's snapshot
    python extract_youtube.py --force      # redo today's snapshot
"""
import argparse, json, logging, os, sys, time
from datetime import datetime, timezone
from pathlib import Path

import requests
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
RAW_ROOT = BASE_DIR / "data" / "raw" / "youtube"

API = "https://www.googleapis.com/youtube/v3"
NDN_CHANNEL_ID = "UCNO66UYt0xSeEMw9d5v-37w"   # @ninedegreesnorthrecords
# Every part a plain API key can read. Cost is 1 unit per call however many parts.
CHANNEL_PARTS = "snippet,statistics,contentDetails,brandingSettings,topicDetails,status,localizations"
VIDEO_PARTS = ("snippet,statistics,contentDetails,status,topicDetails,recordingDetails,"
               "liveStreamingDetails,localizations,player,paidProductPlacementDetails")
BATCH = 50              # the API's maximum IDs per request
MAX_RETRIES = 4
PAUSE_SECONDS = 0.2

log = logging.getLogger("extract_youtube")


class QuotaExceeded(Exception):
    """403 quotaExceeded: retrying today will not help."""


def redact(url: str, key: str) -> str:
    """Never write the API key into files or logs."""
    return url.replace(key, "REDACTED") if key else url


def call_api(endpoint: str, params: dict, key: str, session=requests) -> dict:
    """GET one endpoint. Retries 429/5xx with backoff; stops on other 4xx."""
    params = {**params, "key": key}
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = session.get(f"{API}/{endpoint}", params=params, timeout=30)
            if resp.status_code == 200:
                return {"url": redact(resp.url, key), "payload": resp.json()}
            if resp.status_code == 403 and "quotaExceeded" in resp.text:
                raise QuotaExceeded("daily quota used up; try again after midnight Pacific time")
            if resp.status_code == 429 or resp.status_code >= 500:
                raise requests.HTTPError(f"HTTP {resp.status_code}")
            # 400/401/403/404: our request is wrong (bad key, bad ID). Don't retry.
            raise RuntimeError(f"{endpoint}: HTTP {resp.status_code}: {redact(resp.text[:300], key)}")
        except (requests.ConnectionError, requests.Timeout, requests.HTTPError) as err:
            if attempt == MAX_RETRIES:
                raise
            wait = 2 ** attempt
            log.warning("%s: %s - retry %d/%d in %ds", endpoint, err, attempt, MAX_RETRIES, wait)
            time.sleep(wait)


def save_raw(folder: Path, name: str, result: dict, extracted_at: str) -> Path:
    record = {
        "_meta": {
            "source": "YouTube Data API v3",
            "extracted_at_utc": extracted_at,
            "request_url": result["url"],
        },
        "response": result["payload"],          # exactly what the API returned
    }
    out = folder / f"{name}.json"
    out.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
    return out


def chunks(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def run(key: str, channel_id: str, folder: Path, session=requests) -> dict:
    """Pull channel -> all video IDs -> video stats. Returns a small summary."""
    folder.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    units = 0

    # 1) channel: stats + uploads playlist
    ch = call_api("channels", {"part": CHANNEL_PARTS, "id": channel_id}, key, session)
    units += 1
    save_raw(folder, "channel", ch, stamp)
    items = ch["payload"].get("items", [])
    if not items:
        raise RuntimeError(f"channel {channel_id} not found")
    uploads = items[0]["contentDetails"]["relatedPlaylists"]["uploads"]

    # 2) every video ID in the uploads playlist (paginate with nextPageToken)
    video_ids, page, token = [], 0, None
    while True:
        params = {"part": "contentDetails", "playlistId": uploads, "maxResults": BATCH}
        if token:
            params["pageToken"] = token
        res = call_api("playlistItems", params, key, session)
        units += 1
        page += 1
        video_ids += [it["contentDetails"]["videoId"] for it in res["payload"].get("items", [])]
        token = res["payload"].get("nextPageToken")
        if not token:
            break
        time.sleep(PAUSE_SECONDS)

    # 3) full details for every video, 50 IDs per call
    for n, batch in enumerate(chunks(video_ids, BATCH), start=1):
        res = call_api("videos", {"part": VIDEO_PARTS, "id": ",".join(batch)}, key, session)
        units += 1
        save_raw(folder, f"videos_{n:03d}", res, stamp)
        time.sleep(PAUSE_SECONDS)

    summary = {"extracted_at_utc": stamp, "channel_id": channel_id, "videos": len(video_ids),
               "playlist_pages": page, "quota_units_used": units}
    (folder / "_SUCCESS.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Daily YouTube snapshot for Nine Degrees North.")
    ap.add_argument("--channel", default=NDN_CHANNEL_ID, help="channel ID (starts with UC)")
    ap.add_argument("--force", action="store_true", help="redo today's snapshot")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    load_dotenv(BASE_DIR / ".env")
    key = os.getenv("YOUTUBE_API_KEY", "").strip()
    if not key:
        log.error("YOUTUBE_API_KEY missing. Copy .env.example to .env and paste your key.")
        return 1

    folder = RAW_ROOT / datetime.now(timezone.utc).date().isoformat()
    if (folder / "_SUCCESS.json").exists() and not args.force:   # idempotent
        log.info("Today's snapshot already exists (%s). Use --force to redo.", folder.name)
        return 0

    try:
        summary = run(key, args.channel, folder)
    except QuotaExceeded as err:
        log.error("%s", err)
        return 1
    except Exception as err:
        log.error("FAILED: %s", err)
        return 1
    log.info("Done. videos=%d pages=%d quota_units=%d -> %s",
             summary["videos"], summary["playlist_pages"], summary["quota_units_used"], folder)
    return 0


if __name__ == "__main__":
    sys.exit(main())
