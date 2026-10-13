"""Offline tests for extract_tiktok.py (no internet needed).

Run:  py test_extract_tiktok.py
"""
import json, tempfile, unittest
from pathlib import Path

import extract_tiktok as et


def page(stats, status=0):
    data = {"__DEFAULT_SCOPE__": {"webapp.user-detail": {"statusCode": status,
            "userInfo": {"user": {"uniqueId": "ndn"}, "stats": stats}}}}
    return f'<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{json.dumps(data)}</script></html>'


class FakeResp:
    def __init__(self, status, text="", payload=None):
        self.status_code, self.text, self._payload = status, text, payload

    def json(self):
        return self._payload


class FakeSession:
    def __init__(self, pages):
        self.pages, self.posts = list(pages), []

    def get(self, url, headers=None, timeout=None):
        return self.pages.pop(0)

    def post(self, url, json=None, headers=None, timeout=None):
        self.posts.append((url, json, headers))
        return FakeResp(200, payload={"status": "done"})


def fake_ydl(n):
    class YDL:
        def __init__(self, opts): pass
        def __enter__(self): return self
        def __exit__(self, *a): pass
        def sanitize_info(self, info): return info
        def extract_info(self, url, download):
            return {"id": "ndn", "__files_to_move": {}, "entries": [
                {"id": str(i), "view_count": 15600, "thumbnails": [{"url": "x"}], "http_headers": {"Referer": "y"}}
                for i in range(n)]}
    return YDL


class TestExtractTikTok(unittest.TestCase):
    def setUp(self):
        et.time.sleep = lambda s: None
        self.tmp = Path(tempfile.mkdtemp()) / "2026-10-13"

    def test_saves_profile_and_videos_untouched(self):
        s = et.run("ndn", self.tmp, FakeSession([FakeResp(200, page({"followerCount": 319600, "videoCount": 10}))]), fake_ydl(10))
        self.assertEqual((s["videos"], s["followers"]), (10, 319600))
        prof = json.loads((self.tmp / "profile.json").read_text(encoding="utf-8"))
        self.assertEqual(prof["response"]["userInfo"]["stats"]["followerCount"], 319600)
        self.assertTrue((self.tmp / "_SUCCESS.json").exists())

    def test_drops_expiring_thumbnail_urls(self):
        et.run("ndn", self.tmp, FakeSession([FakeResp(200, page({"videoCount": 3}))]), fake_ydl(3))
        e = json.loads((self.tmp / "videos.json").read_text(encoding="utf-8"))["response"]["entries"][0]
        self.assertNotIn("thumbnails", e)
        self.assertNotIn("http_headers", e)
        self.assertEqual(e["view_count"], 15600)

    def test_partial_scrape_is_rejected(self):
        with self.assertRaises(RuntimeError):
            et.run("ndn", self.tmp, FakeSession([FakeResp(200, page({"videoCount": 100}))]), fake_ydl(50))
        self.assertFalse((self.tmp / "_SUCCESS.json").exists())

    def test_blocked_profile_page_retries_then_fails(self):
        sess = FakeSession([FakeResp(403, "blocked")] * et.MAX_RETRIES)
        with self.assertRaises(RuntimeError):
            et.run("ndn", self.tmp, sess, fake_ydl(1))
        self.assertEqual(sess.pages, [])                  # all retries used

    def test_upload_sends_secret_header_and_both_files(self):
        et.run("ndn", self.tmp, FakeSession([FakeResp(200, page({"videoCount": 2}))]), fake_ydl(2))
        sess = FakeSession([])
        et.upload(self.tmp, "https://x.supabase.co/", "S3CRET", "github", sess)
        url, body, headers = sess.posts[0]
        self.assertEqual(url, "https://x.supabase.co/functions/v1/tiktok-ingest?by=github")
        self.assertEqual(headers["x-cron-secret"], "S3CRET")
        self.assertEqual(set(body["files"]), {"profile", "videos"})
        self.assertEqual(body["snapshot_date"], "2026-10-13")


if __name__ == "__main__":
    unittest.main(verbosity=2)
