# Step 1: Extract (YouTube)

## The big picture
Same ELT idea as the weather project: **get the data and save it exactly as received**. Cleaning happens later in SQL.

What's new here:
1. **An API key.** Open-Meteo needed none. YouTube needs a key so Google can count your usage.
2. **Pagination.** The API returns at most 50 items per call. To get every video you follow `nextPageToken` until there isn't one.
3. **Snapshots.** The API gives you today's totals only ("this video has 134M views now"). To see growth you must save a copy every day. That's why each run writes to its own date folder: `data/raw/youtube/2026-10-12/`.

## How the script gets every video (3 calls)
```
channels.list (1 call)         → channel stats + ID of the hidden "uploads" playlist
playlistItems.list (1 per 50)  → every video ID on the channel (used in memory, not saved)
videos.list (1 per 50 IDs)     → every public field: stats, duration, title, description, tags,
                                 topics, privacy/license, premiere times, paid-promo flag
```
Every channel has an "uploads" playlist containing all its videos. Reading that playlist costs 1 quota unit per page. The `search` endpoint costs 100 per call and stops at ~500 results, so we avoid it. The playlist pages only hold IDs and dates that `videos.list` also returns, so the script doesn't save them: they are a lookup, not data.

Asking for more `part`s costs nothing extra: a call is 1 unit whether you request 3 parts or 10. So the script requests every part a plain API key can read.

## Quota
You get **10,000 units per day**, free. NDN (1,017 videos) costs **43 units** per snapshot (1 channel + 21 playlist pages + 21 video batches). The script prints `quota_units` so you can see it. Quota resets at midnight Pacific time (3 or 4 pm in the Philippines).

## Protecting your key
- The key lives in `.env`, which `.gitignore` keeps out of GitHub.
- `redact()` replaces the key with `REDACTED` before any URL is saved or logged. A test checks this.
- Restrict the key to YouTube Data API v3 in Google Cloud (you did this in Step 0).

## Errors the script handles
| Error | What it means | What the script does |
|---|---|---|
| 429 / 5xx | busy or broken server | waits 2s, 4s, 8s, retries |
| 403 `quotaExceeded` | daily quota used up | stops immediately; retrying won't help |
| 400 / 403 other | bad key or bad request | stops and prints the reason |

## Run it (Windows, in the project folder)
```
pip install -r requirements.txt
copy .env.example .env
notepad .env                    # paste the key after YOUTUBE_API_KEY=  then save
python test_extract_youtube.py  # 5 offline tests, should say OK
python extract_youtube.py
```
Expect a line like `Done. videos=... pages=... quota_units=...`. Run it again the same day and it says the snapshot already exists (idempotent).

## Exercises
1. Open `data/raw/youtube/<today>/channel.json`. Find the subscriber count and the uploads playlist ID.
2. Open `videos_001.json`. Pick one Cozy Cove video and find its `viewCount`, `likeCount`, `duration` and `publishedAt`. What format is `duration` in? (We'll convert it in SQL.)
3. Notice the numbers are strings (`"134000000"`), not numbers. Why might an API do that? Where should we convert them: here or in SQL?
4. Look at a few titles. Write down the pattern you'd use to split "Song (Live at The Cozy Cove) - Artist" into song and artist. Find one title that breaks your pattern.
5. Run tomorrow and compare the same video's `viewCount` across the two date folders. That difference is "views gained per day", the core metric of this project.

## Next
Step 2: Load. Create the `raw` schema in Supabase and load each day's JSON files into a table, untouched, with the snapshot date.
