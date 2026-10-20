# Data set 6: benchmark accounts (brief, 2026-10-21; nothing built yet)

Goal (Vic, 2026-10-21): **collect all the data we can get for free** on comparable PH live-session accounts, for the
dashboard's 5th page "Benchmark" (`TABLEAU_DATA.md`: weekly stats vs NDN, indexed to 100 at the first week) and the
invite score's Momentum part.

## Accounts

| Account | Given by | TikTok | YouTube | Instagram |
|---|---|---|---|---|
| Wish 107.5 (Wish Bus) | Claude, 2026-10-20 | @wish1075official (profile weekly since 2026-10-20) | to find | to find |
| jessxpats | Vic, 2026-10-21 | @jessxpats (added to `raw.tiktok_accounts` 2026-10-21) | to find | to find |
| backyard.live | Vic, 2026-10-21 | @backyard.live (added 2026-10-21) | to find | to find |
| 2 more | Claude proposes, Vic OKs | | | |

Find each account's YouTube and Instagram from its TikTok bio / website first; don't guess handles.

## What "all the free data" means per platform (to check and build)

- **TikTok:** profile snapshot weekly (built, `tiktok-extras`). Add: their video list + per-video stats (same scraper as NDN's, weekly).
- **YouTube:** Data API: channel stats daily or weekly, uploads list + per-video views/likes/comments (cheap: about 1 unit per 50 videos). Their comments: optional, same function as `youtube-comments`.
- **Instagram:** Business Discovery (Business/Creator accounts only): followers, media count, per-post likes/comments/views/reposts, 1 call per account.
- **Not free:** watch time, audience, Facebook. Same limits as NDN.

## Open questions for the build session
1. Which 2 more accounts (propose with reasons: PH, live sessions, similar size or the leader to chase).
2. Weekly or daily snapshots for benchmarks (size: check DB, ~230/500 MB after YouTube comments).
