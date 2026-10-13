# Step 6: TikTok (scraped public data)

## Why scraping
TikTok's official APIs need either NDN's login (Display API, Phase 2) or academic approval
(Research API). So we read what any visitor sees. This is unofficial: TikTok's terms forbid
scraping, and a site change can break it. We keep it to one quiet run per day, public numbers
only, and label it "scraped public data" in the README.

## Two sources
```
tiktok.com/@ninedegreesnorth (HTML) ──▶ <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__"> JSON
                                          └─ followers, total likes, video count   → profile.json
yt-dlp --flat-playlist                 ──▶ every video: views, likes, comments,
                                          shares (repost_count), saves, duration   → videos.json
```
- **Embedded JSON:** many modern sites ship the page's data as JSON inside a `<script>` tag so
  the browser can draw the page. Reading it is far more stable than parsing the visible HTML.
- **yt-dlp** knows how to sign TikTok's internal requests and page through the video list.
  We use it as a Python library and never download any video.

## Daily flow
```
GitHub Actions 01:00 UTC → extract_tiktok.py --upload → Edge Function tiktok-ingest → raw.tiktok_responses
                                                                                    raw.tiktok_runs
```
The scrape can't run inside Supabase (Edge Functions run TypeScript, not Python), so GitHub
runs it and the function only loads. Same secret header as youtube-snapshot.

## Data quality notes for Step 3
- **Rounding:** TikTok sends counts ≥ 10,000 rounded to 3 digits (9.9M, 15.6K). Daily gains on
  big videos move in steps; small videos are exact. Phase 2 access gives exact numbers.
- **Coverage check:** if yt-dlp returns < 90% of the profile's video count, the run fails rather
  than saving a misleading day.
- Captions (`description`) hold song/artist, e.g. `Kahit Na Umulan (Live at The Cozy Cove) by Fern.`
  Note "by" here vs "-" on YouTube.
- Timestamps are Unix seconds (UTC).

## Exercises
1. Open `data/raw/tiktok/<date>/profile.json`. Find `followerCount` and `heart`. Why might `heart` look rounded?
2. In `videos.json`, find the video with the most `save_count`. Is it also the most viewed?
3. Convert one `timestamp` to a Philippine date and time by hand (UTC+8). Check with Python:
   `datetime.fromtimestamp(ts, timezone.utc)`.
4. Why does the script refuse to save a day when yt-dlp returns fewer than 90% of the videos?
   What would a half-scraped day do to a "views gained per day" chart?
5. Find one caption that names an artist with "by" and one with "-". Write the regex you'd use to catch both.
