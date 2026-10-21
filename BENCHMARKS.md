# Data set 6: benchmark accounts (brief 2026-10-21; built 2026-10-21, see "Built" below)

Goal (Vic, 2026-10-21): **collect all the data we can get for free** on comparable PH live-session accounts, for the
dashboard's 5th page "Benchmark" (`TABLEAU_DATA.md`: weekly stats vs NDN, indexed to 100 at the first week) and the
invite score's Momentum part.

## Accounts (v2, Vic 2026-10-21: domestic, Asia, international; `sql/021_benchmarks_v2.sql`)

Handles from each account's own YouTube links page / bio; TikTok accounts checked verified (except Backyard Live).

| Region | Account | TikTok | YouTube | Instagram |
|---|---|---|---|---|
| domestic | Wish 107.5 (Wish Bus) | @wish1075official | UCdfq8-581QVUtVsa8ChVnDQ (16.1M) | wish1075 |
| domestic | Backyard Live | @backyard.live | UC1P5pdk6RAUJqaIRPUC0jWg (40k) | backyard.live |
| asia | THE FIRST TAKE (Japan) | @the_first_take | UC9zY_E8mcAo_Oq772LEZq8Q (12.4M) | the_firsttake |
| asia | it's Live (Korea, MBC) | @itslive_official | UCB9e3pof1o83aa0kkaoeJGA (2.34M) | itslive_official |
| international | NPR Music (Tiny Desk) | @npr_music (started Feb 2026) | UC4eYXhJI4-7wSWc8UNRwD4A (13.1M) | nprmusic |

- Tiny Desk has no channel of its own: NPR Music's totals include its other videos.
- Dropped 2026-10-21 (kept inactive, one day of data): Jess & Pat's, Tower of Doom, Vibe PH.

## Past data (Vic: real past data beats synthetic)

- **Got (free, real):** a one-time catalog of every upload with today's counts, pulled 2026-10-21:
  YouTube all videos (12,965), TikTok all videos yt-dlp lists (it's Live: only 420 of ~2,680, TikTok cut the
  list short), Instagram since 2024-01-01. → `mart.benchmark_upload_history`: uploads and current views per
  month of upload. Older months had longer to collect views: compare accounts within a month, not months.
- **Not available free:** follower history before 2026-10-21. Social Blade's free page shows 14 days (YouTube
  only; TikTok/Instagram pages are behind a bot check); the Wayback Machine is blocked on Vic's network (DNS
  fails on the PC and the server). Growth lines start 2026-10-21.
- Instagram catalogs for Backyard, NPR and Wish hit Meta's hourly app limit; one-time pg_cron jobs retry them
  19:20 / 19:25 / 20:30 PH 2026-10-21 and remove themselves at 21:00.

## What "all the free data" means per platform (to check and build)

- **TikTok:** profile snapshot weekly (built, `tiktok-extras`). Add: their video list + per-video stats (same scraper as NDN's, weekly).
- **YouTube:** Data API: channel stats daily or weekly, uploads list + per-video views/likes/comments (cheap: about 1 unit per 50 videos). Their comments: optional, same function as `youtube-comments`.
- **Instagram:** Business Discovery (Business/Creator accounts only): followers, media count, per-post likes/comments/views/reposts, 1 call per account.
- **Not free:** watch time, audience, Facebook. Same limits as NDN.

## Scope decided (Vic, 2026-10-21): small on purpose, to save database space

Vic only wants to see each benchmark's **overall growth** and their **top 10 trending videos right now**. So instead of
"all the free data" per video:
- **Daily: account totals only** per platform (followers/subscribers, total views or likes, video count). ~15 rows a day.
- **Weekly: top 10 trending per account per platform** = the 10 videos with the most views gained in the last 7 days.
  To get the gain: read the counts of their recent uploads (e.g. last ~50) each week, store counts only (no titles
  repeated, no descriptions; title once per video), keep the top 10 for the dashboard.
- No per-video daily history, no benchmark comments.
- Size estimate: ~0.2 MB a day for all benchmarks (measure in the build session).


## Built (2026-10-21, `sql/020_benchmarks.sql`)

| What | Where | When (PH) |
|---|---|---|
| Account list | `raw.benchmark_accounts` (one row per account, all 3 handles) | |
| Daily totals | `raw.benchmark_daily`: followers, YouTube channel views, TikTok hearts, post count | YouTube + Instagram 09:20 pg_cron `ndn-benchmarks-daily`; TikTok after the 09:00 NDN run (GitHub `daily.yml`) |
| Latest 50 uploads, counts only | `raw.benchmark_video_weekly` + titles once in `raw.benchmark_video` | Mon 11:20 pg_cron `ndn-benchmarks-weekly`; TikTok Mon 10:30 (GitHub `weekly.yml`) |
| Growth vs NDN | `mart.benchmark_growth` (followers indexed to 100 on day 1; NDN real data added) | |
| Top 10 trending | `mart.benchmark_top10` (views gained since last week, scaled to 7 days) | |

- Collected by Edge Function `benchmarks` (YouTube API ~11 units/week + 1/day; Instagram Business Discovery 5
  calls/day + 5/week) and `extract_benchmarks_tiktok.py` (profile page, browser fallback; yt-dlp latest 50).
- The weekly TikTok profile job no longer snapshots benchmark accounts (`raw.tiktok_accounts` rows set inactive).
- **Instagram hides Reel views for Backyard Live (and Vibe PH, dropped)**: their top 10 ranks by likes gained (`measure` column).
  For the others only Reels have views, so photo posts drop out of their ranking.
- First weekly snapshot taken 2026-10-21 (Wed), so the first top 10 appears after Mon 2026-10-26 (5-day gain, scaled to 7).
- Size: 7.8 MB after the catalogs (2026-10-21); then ~15 rows/day + ~750 rows/week.
