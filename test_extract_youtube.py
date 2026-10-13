"""Offline tests for extract_youtube.py (no internet, no real key needed).

Run:  python test_extract_youtube.py
"""
import json, tempfile, unittest
from pathlib import Path
from urllib.parse import urlencode

import extract_youtube as ey

KEY = "FAKE_KEY_123"


class FakeResp:
    def __init__(self, status, payload, url):
        self.status_code, self._payload, self.url = status, payload, url
        self.text = json.dumps(payload)

    def json(self):
        return self._payload


class FakeYouTube:
    """Pretends to be YouTube: a channel with 60 uploads (2 playlist pages)."""
    def __init__(self, n_videos=60, quota_error=False):
        self.ids = [f"vid{i:03d}" for i in range(n_videos)]
        self.quota_error = quota_error
        self.calls = []

    def get(self, url, params=None, timeout=None):
        full = url + "?" + urlencode(params)
        endpoint = url.rsplit("/", 1)[-1]
        self.calls.append(endpoint)
        if self.quota_error:
            return FakeResp(403, {"error": {"errors": [{"reason": "quotaExceeded"}]}}, full)
        if endpoint == "channels":
            return FakeResp(200, {"items": [{"id": "UCtest", "statistics": {"subscriberCount": "463000"},
                "contentDetails": {"relatedPlaylists": {"uploads": "UUtest"}}}]}, full)
        if endpoint == "playlistItems":
            start = 50 if params.get("pageToken") == "P2" else 0
            page = self.ids[start:start + 50]
            body = {"items": [{"contentDetails": {"videoId": v}} for v in page]}
            if start + 50 < len(self.ids):
                body["nextPageToken"] = "P2"
            return FakeResp(200, body, full)
        if endpoint == "videos":
            ids = params["id"].split(",")
            return FakeResp(200, {"items": [{"id": v, "statistics": {"viewCount": "1"}} for v in ids]}, full)
        return FakeResp(404, {}, full)


class TestExtract(unittest.TestCase):
    def setUp(self):
        ey.PAUSE_SECONDS = 0
        self.tmp = Path(tempfile.mkdtemp())

    def test_paginates_and_batches(self):
        yt = FakeYouTube(60)
        s = ey.run(KEY, "UCtest", self.tmp, session=yt)
        self.assertEqual(s["videos"], 60)
        self.assertEqual(s["playlist_pages"], 2)
        self.assertEqual(yt.calls.count("videos"), 2)        # 50 + 10
        self.assertEqual(s["quota_units_used"], 1 + 2 + 2)
        self.assertTrue((self.tmp / "_SUCCESS.json").exists())
        self.assertEqual(list(self.tmp.glob("playlist_items_*.json")), [])   # lookup only
        self.assertEqual(len(list(self.tmp.glob("videos_*.json"))), 2)

    def test_key_never_written_to_disk(self):
        ey.run(KEY, "UCtest", self.tmp, session=FakeYouTube(5))
        for f in self.tmp.glob("*.json"):
            self.assertNotIn(KEY, f.read_text(encoding="utf-8"), f.name)

    def test_raw_response_saved_untouched(self):
        ey.run(KEY, "UCtest", self.tmp, session=FakeYouTube(5))
        rec = json.loads((self.tmp / "channel.json").read_text(encoding="utf-8"))
        self.assertEqual(rec["response"]["items"][0]["statistics"]["subscriberCount"], "463000")
        self.assertIn("extracted_at_utc", rec["_meta"])

    def test_quota_exceeded_stops_without_retry(self):
        yt = FakeYouTube(quota_error=True)
        with self.assertRaises(ey.QuotaExceeded):
            ey.run(KEY, "UCtest", self.tmp, session=yt)
        self.assertEqual(len(yt.calls), 1)

    def test_missing_key_fails_cleanly(self):
        import os
        old = os.environ.pop("YOUTUBE_API_KEY", None)
        orig = ey.load_dotenv
        ey.load_dotenv = lambda *a, **k: None          # ignore any real .env
        try:
            self.assertEqual(ey.main([]), 1)
        finally:
            ey.load_dotenv = orig
            if old is not None:
                os.environ["YOUTUBE_API_KEY"] = old


if __name__ == "__main__":
    unittest.main(verbosity=2)
