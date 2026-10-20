"""Spotify artist pages + kworb, weekly (sql/015_spotify_kworb.sql). Extract here, Load through the
spotify-weekly Edge Function (asks it what to fetch, posts the results back). Unofficial: the
logged-out Spotify web player's own API, read through a headless browser (the Web API needs
Premium since Feb 2026 and no longer gives followers).

Steps (each only for what is new or due):
  search   find the Spotify artist for each NDN artist and listed TikTok artist account:
           kworb chart link > track search confirmed by an NDN song > exact name (Vic checks)
  artists  each artist page: monthly listeners, followers, world rank, top 5 cities, top tracks
  kworb    each artist's kworb.net songs page: total and daily streams per song (plain request)

    py extract_spotify.py                          # all steps
    py extract_spotify.py --steps search --dry-run # print picks, save nothing
    py extract_spotify.py --check                  # does Spotify + kworb answer from this machine?
Needs SUPABASE_URL and NDN_CRON_SECRET (.env or environment). Also: playwright + chromium.
"""
import argparse, html, json, logging, os, re, sys, time

import requests
from dotenv import load_dotenv

STEPS = ["search", "artists", "kworb"]
PATHFINDER = "https://api-partner.spotify.com/pathfinder/v2/query"
WARM_ARTIST = "3LiUry0ss8UpPzbBmM9bDP"      # Esremborak: any artist page, to catch the API calls
OPS = ("queryArtistOverview", "searchArtists", "searchDesktop")
KWORB = "https://kworb.net/spotify/artist/{}_songs.html"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
SURE = ("kworb_chart", "bio_link", "confirmed_by_song", "manual")
SAVE_EVERY = 25
MAX_FAILS = 15

log = logging.getLogger("extract_spotify")


def key(text):
    """Same as staging.name_key: lower case, letters and digits only."""
    return "".join(c for c in (text or "") if c.isalnum()).lower()


class Feed:
    def __init__(self, base_url, secret, by):
        self.url = base_url.rstrip("/") + "/functions/v1/spotify-weekly"
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


# ---------------------------------------------------------------- Spotify (headless browser)
class Spotify:
    """Opens one artist page and one search page, copies the web player's own API calls (token
    headers + query ids), then repeats them with other artists or names."""

    def __init__(self):
        from playwright.sync_api import sync_playwright
        self._pw = sync_playwright().start()
        self.browser = self._pw.chromium.launch(headless=True)
        self.page = self.browser.new_page(locale="en-US", user_agent=UA)
        self.headers, self.calls = {}, {}
        self.page.on("request", self._catch)
        self.warm()

    def _catch(self, req):
        if req.url.startswith(PATHFINDER) and req.post_data:
            body = json.loads(req.post_data)
            if body.get("operationName") in OPS:
                self.calls[body["operationName"]] = body
                self.headers = {k: v for k, v in req.headers.items()
                                if k in ("authorization", "client-token", "app-platform", "spotify-app-version", "content-type")}

    def warm(self):
        self.calls.clear()
        for url, ops in ((f"https://open.spotify.com/artist/{WARM_ARTIST}", OPS[:1]),
                         ("https://open.spotify.com/search/esremborak/artists", OPS[1:])):
            self.page.goto(url, wait_until="domcontentloaded", timeout=60_000)
            for _ in range(40):
                if all(op in self.calls for op in ops):
                    break
                self.page.wait_for_timeout(500)
        missing = [op for op in OPS if op not in self.calls]
        if missing:
            raise RuntimeError(f"Spotify web player did not make these calls: {missing}")

    def query(self, op, **variables):
        body = json.loads(json.dumps(self.calls[op]))
        body["variables"].update(variables)
        for attempt in range(3):
            r = self.page.request.post(PATHFINDER, headers=self.headers, data=json.dumps(body), timeout=30_000)
            if r.status == 200:
                return r.json()
            if r.status in (401, 403):        # token expired: open the pages again for a fresh one
                self.warm()
            else:
                time.sleep(3 * (attempt + 1))
        raise RuntimeError(f"{op}: HTTP {r.status}")

    def overview(self, spotify_id):
        a = self.query("queryArtistOverview", uri=f"spotify:artist:{spotify_id}")["data"]["artistUnion"]
        if a.get("__typename") != "Artist":
            raise RuntimeError(f"{spotify_id}: {a.get('__typename')}")
        return a

    def search_artists(self, name):
        items = self.query("searchArtists", searchTerm=name, limit=10, offset=0)["data"]["searchV2"]["artists"]["items"]
        out = []
        for it in items:
            d = it.get("data") or {}
            if d.get("__typename") == "Artist":
                out.append({"id": d["uri"].split(":")[-1], "name": d["profile"]["name"],
                            "verified": ((d.get("onPlatformReputationTrait") or {}).get("verification") or {}).get("isVerified")})
        return out

    def search_tracks(self, text):
        data = self.query("searchDesktop", searchTerm=text, limit=10, offset=0)["data"]["searchV2"]
        out = []
        for it in (data.get("tracksV2") or {}).get("items", []):
            t = (it.get("item") or {}).get("data") or {}
            if t.get("name"):
                out.append({"name": t["name"], "artists": [
                    {"id": a["uri"].split(":")[-1], "name": a["profile"]["name"]} for a in t.get("artists", {}).get("items", [])]})
        return out

    def close(self):
        self.browser.close()
        self._pw.stop()


def slim(a):
    """Keep only what sql/015 uses from the artist page (the full answer is ~200 KB of images)."""
    disc = a.get("discography") or {}
    latest = disc.get("latest") or {}
    return {
        "profile": {"name": a["profile"]["name"],
                    "verified": ((a.get("onPlatformReputationTrait") or {}).get("verification") or {}).get("isVerified",
                                a["profile"].get("verified"))},
        "stats": a.get("stats"),
        "topTracks": [{"id": t["track"]["id"], "name": t["track"]["name"], "playcount": t["track"].get("playcount")}
                      for t in (disc.get("topTracks") or {}).get("items", []) if t.get("track")],
        "releases": {"albums": (disc.get("albums") or {}).get("totalCount"),
                     "singles": (disc.get("singles") or {}).get("totalCount"),
                     "latest": {"name": latest.get("name"), "type": latest.get("type"),
                                "date": (latest.get("date") or {}).get("isoString", "")[:10] or None} if latest else None},
    }


def release_titles(a):
    disc = a.get("discography") or {}
    names = [t["track"]["name"] for t in (disc.get("topTracks") or {}).get("items", []) if t.get("track")]
    names += [r.get("name", "") for r in (disc.get("popularReleasesAlbums") or {}).get("items", [])]
    for part in ("albums", "singles", "compilations"):
        for it in (disc.get(part) or {}).get("items", []):
            names += [r.get("name", "") for r in (it.get("releases") or {}).get("items", [])]
    return {key(n) for n in names if n}


def song_match(song_keys, title):
    t = key(title)
    return next((s for s in song_keys if t == s or (len(s) >= 5 and t.startswith(s))), None)


def pick_artist(sp, item):
    """Return {spotify_id, name, match_type, evidence} or None, plus the name-search results."""
    if item.get("chart_id"):
        a = sp.overview(item["chart_id"])
        return {"spotify_id": item["chart_id"], "name": a["profile"]["name"], "match_type": "kworb_chart",
                "evidence": "artist link on the kworb Spotify PH weekly chart"}, []
    want = key(item["query"])
    results = sp.search_artists(item["query"])
    exact = [r for r in results if key(r["name"]) == want]
    songs = {key(s): s for s in item.get("songs") or [] if len(key(s)) >= 3}

    # 1) an NDN song by this artist name, found by track search
    for sk, song in list(songs.items())[:4]:
        for t in sp.search_tracks(f"{song} {item['query']}"):
            if song_match([sk], t["name"]):
                for ar in t["artists"]:
                    if key(ar["name"]) == want:
                        return {"spotify_id": ar["id"], "name": ar["name"], "match_type": "confirmed_by_song",
                                "evidence": f"song '{t['name']}'"}, results
    # 2) an NDN song among the releases of an exact-name artist
    for r in exact[:3]:
        hit = next((s for s in songs if s in release_titles(sp.overview(r["id"]))), None) if songs else None
        if hit:
            return {"spotify_id": r["id"], "name": r["name"], "match_type": "confirmed_by_song",
                    "evidence": f"release '{songs[hit]}'"}, results
    # 3) name only: Vic checks before it is used
    if exact:
        return {"spotify_id": exact[0]["id"], "name": exact[0]["name"],
                "match_type": "exact" if len(exact) == 1 else "shared_name",
                "evidence": f"{len(exact)} Spotify artist(s) with this exact name; no NDN song found"}, results
    return None, results


# ---------------------------------------------------------------- kworb (plain request)
ROW_RE = re.compile(r'<tr><td class="text"><div>(\*?)\s*<a href="https://open\.spotify\.com/track/([A-Za-z0-9]+)"[^>]*>(.*?)</a>'
                    r'</div></td><td>([\d,]+)</td><td>([\d,]*)</td></tr>')
TOTAL_RE = re.compile(r'<td class="text">(Streams|Daily|Tracks)</td><td>([\d,]+)</td>'
                      r'<td class="smaller">([\d,]+)</td><td class="smaller">([\d,]+)</td><td class="smaller">([\d,]+)</td>')


def num(s):
    return int(s.replace(",", "")) if s else None


def kworb_page(session, spotify_id):
    r = session.get(KWORB.format(spotify_id), timeout=30)
    if r.status_code == 404:
        return {"spotify_id": spotify_id, "found": False}
    r.raise_for_status()
    page = r.text
    upd = re.search(r"Last updated: (\d{4})/(\d{2})/(\d{2})", page)
    songs = [{"track_id": tid, "title": html.unescape(title), "streams": num(st), "daily": num(dy), "feature": bool(star)}
             for star, tid, title, st, dy in ROW_RE.findall(page)]
    # totals table: Total, As lead, Solo, As feature (*)
    totals = {k.lower(): num(t) for k, t, *_ in TOTAL_RE.findall(page)}
    totals.update({f"{k.lower()}_{col}": num(v) for k, *vals in TOTAL_RE.findall(page)
                   for col, v in zip(("lead", "solo", "feature"), vals[1:])})
    if not songs:
        raise RuntimeError(f"kworb {spotify_id}: page has no song rows (layout changed?)")
    return {"spotify_id": spotify_id, "found": True, "kworb_updated": "-".join(upd.groups()) if upd else None,
            "payload": {"totals": totals, "songs": songs}}


# ---------------------------------------------------------------- run
def run_step(step, feed, limit, dry_run, state):
    items = feed.todo(step, limit)
    log.info("%s: %d to fetch", step, len(items))
    rows, done, fails, picks = [], 0, 0, {}
    session = None
    if step == "kworb":
        session = requests.Session()
        session.headers["User-Agent"] = UA
    elif state.get("sp") is None:
        state["sp"] = Spotify()
    sp = state.get("sp")
    for it in items:
        try:
            if step == "search":
                pick, results = pick_artist(sp, it)
                picks[pick["match_type"] if pick else "none"] = picks.get(pick["match_type"] if pick else "none", 0) + 1
                print(json.dumps({"query": it["query"], "pick": pick, "top": results[:3]}, ensure_ascii=False), flush=True)
                rows.append({"query_key": it["query_key"], "query": it["query"], "name_key": it.get("name_key"),
                             "tiktok_handle": it.get("tiktok_handle"), "results": results, "pick": pick})
            elif step == "artists":
                rows.append({"spotify_id": it["spotify_id"], "payload": slim(sp.overview(it["spotify_id"]))})
            else:
                rows.append(kworb_page(session, it["spotify_id"]))
                time.sleep(1)                 # kworb is one person's site: one page a second
            done += 1
        except Exception as e:
            fails += 1
            log.warning("%s %s: %s", step, it.get("query") or it.get("spotify_id"), str(e)[:200])
            if fails >= MAX_FAILS:
                log.error("%s: %d failures, stopping this step", step, fails)
                break
        if len(rows) >= SAVE_EVERY and not dry_run:
            feed.save(step, rows)
            rows = []
    if not dry_run:
        feed.save(step, rows)
    return {"to_fetch": len(items), "done": done, "failed": fails, **({"picks": picks} if picks else {})}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", default=",".join(STEPS))
    ap.add_argument("--limit", type=int, default=2000)
    ap.add_argument("--by", default="manual")
    ap.add_argument("--dry-run", action="store_true", help="fetch and print, save nothing")
    ap.add_argument("--check", action="store_true", help="only test that Spotify and kworb answer from here")
    args = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")      # names like DENȲ or Mỹ Anh on a Windows console
    sys.stderr.reconfigure(encoding="utf-8")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    load_dotenv()
    if args.check:
        sp = Spotify()
        stats = slim(sp.overview(WARM_ARTIST))["stats"]
        sp.close()
        k = requests.get(KWORB.format(WARM_ARTIST), headers={"User-Agent": UA}, timeout=30).status_code
        print(f"Spotify OK: Esremborak {stats['monthlyListeners']:,} monthly listeners; kworb HTTP {k}")
        return
    feed = Feed(os.environ["SUPABASE_URL"], os.environ["NDN_CRON_SECRET"], args.by)
    detail, state, status = {}, {}, "ok"
    try:
        for step in [s.strip() for s in args.steps.split(",") if s.strip()]:
            if step not in STEPS:
                sys.exit(f"unknown step {step}")
            detail[step] = run_step(step, feed, args.limit, args.dry_run, state)
            if detail[step]["failed"]:
                status = "partial"
    except Exception as e:
        status, detail["error"] = "failed", str(e)[:500]
        log.exception("run failed")
    finally:
        if state.get("sp"):
            state["sp"].close()
    log.info("%s %s", status, json.dumps(detail))
    if not args.dry_run:
        feed.log_run(status, detail)
    sys.exit(1 if status == "failed" else 0)


if __name__ == "__main__":
    main()
