# Data set 6: benchmark accounts (brief 2026-10-21; built 2026-10-21, see "Built" below)

Goal (Vic, 2026-10-21): **collect all the data we can get for free** on comparable PH live-session accounts, for the
dashboard's 5th page "Benchmark" (`TABLEAU_DATA.md`: weekly stats vs NDN, indexed to 100 at the first week) and the
invite score's Momentum part.

## Accounts

Handles checked 2026-10-21 from each account's own bio, YouTube links page or website (not guessed).

| Account | Given by | TikTok | YouTube | Instagram |
|---|---|---|---|---|
| Wish 107.5 (Wish Bus) | Claude, 2026-10-20 | @wish1075official | UCdfq8-581QVUtVsa8ChVnDQ (@wishfm1075official) | wish1075 |
| Jess & Pat's | Vic, 2026-10-21 | @jessxpats | UCPBPWR8nuHPKt5X_qPk3t1A (12 videos, inactive since May 2020) | jessxpats |
| Backyard Live | Vic, 2026-10-21 | @backyard.live | UC1P5pdk6RAUJqaIRPUC0jWg | backyard.live |
| Tower of Doom (Tower Sessions) | Claude, OK by Vic 2026-10-21 | none listed | UCh__YhmGdnvPh5fSdF8DJnQ (@towerofdoomrecords) | towerofdoom |
| Vibe PH (Vibe+) | Claude, OK by Vic 2026-10-21 | @vibeph.tv | UC6hmtt5JtP0e_FNAtWsq2Yw (@vibephtv) | vibeph.tv |

**Why these 2** (picked from NDN's own data: `staging.youtube_search_result`, the channels that rank next to NDN in
the 90 weekly song searches, keeping those that post live performances and are still active):
- **Tower of Doom**: the closest peer. Same format (indie OPM studio live sessions, "Tower Sessions"), 1.21M YouTube
  subscribers vs NDN 1.51M, and it ranks higher than anyone else for NDN's songs (average rank 5.3 in 9 searches).
- **Vibe PH**: the fast riser. TV5's all-OPM countdown with live performances ("Legit Vibe"), channel started
  April 2025, already 49k subscribers / 19M views; shows up in 12 of NDN's searches.
- Left out: All Music MYX (MYX Live! performances, 13 searches, but no upload since April 2020); karaoke/lyric
  channels (rank often, but not live sessions).
To drop one: `update raw.benchmark_accounts set active = false where account_key = 'tower';`

Find each account's YouTube and Instagram from its TikTok bio / website first; don't guess handles.

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
- **Instagram hides Reel views for Backyard Live and Vibe PH**: their top 10 ranks by likes gained (`measure` column).
  For the others only Reels have views, so photo posts drop out of their ranking.
- First weekly snapshot taken 2026-10-21 (Wed), so the first top 10 appears after Mon 2026-10-26 (5-day gain, scaled to 7).
- Size: 0.47 MB for the first day + first weekly run (all 5 accounts); then ~13 rows/day + ~700 rows/week.
