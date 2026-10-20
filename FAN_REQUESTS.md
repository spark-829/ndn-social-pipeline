# Data set 5: fan requests in comments (plan, 2026-10-21)

Goal: find which artists (and which filmed sessions) fans ask NDN for, so the invite score's **Fan demand (15%)** part (`INVITE_SCORE.md`) has real numbers. Sources: TikTok comments (collected weekly since 2026-10-20, `staging.tiktok_comment`) and YouTube comments (new, below). Instagram comment text is refused by the API (tested 2026-10-21) → Phase 2.

## What the TikTok comments already show (first look, 2026-10-21, real)

- 20,723 top-level comments on 860 videos.
- Request words alone don't work. "sana" (I wish) mostly turns up lyrics, prayers and self-promotion ("please listen to my songs"), not requests.
- Start from names instead. 1,187 comments name an active artist from `staging.spotify_artist` (whole-word match): 745 on that artist's own video (praise), 464 name a **different** artist.
- Of those 464, 55 also have a request word. In a 30-comment sample about half were real requests. Kinds seen:
  - artist request ("<artist> please 🙏", "<artist> next", "bring <band> back to Cozy Cove")
  - song request ("<song> by <artist> next")
  - collab request ("<artist A> x <artist B> please")
  - **upload request**: a session that was filmed but not posted yet ("why isn't <artist> ft <artist> uploaded, it was 2025")
  - noise: lyrics quoted with the artist's name, wedding wishes, gossip, other channels' collabs
- Short names need a stoplist: "because", "this band", "sica" (inside "musica"), "nicole", "demi" are false matches. Bare first names ("janine", "maki") are fine only if they map to one artist.

Conclusion: names + rules find the **candidates** well, but only about half are real requests. A reading step is needed to label them.

## Part A: YouTube comments extract

| Item | Plan |
|---|---|
| API call | `commentThreads.list` (part=snippet, maxResults=100, order=time, textFormat=plainText). 1 quota unit per page of 100 |
| Replies | Skip (same as TikTok: requests are top-level; replies are conversation) |
| Fields kept | comment id, video id, text, published/updated time, like count, reply count, author channel id. **No display name, no avatar** |
| Backfill | 1,020 videos, ~180k comments incl. replies → at most ~2,450 units, once, on a non-Monday (Monday's 90 searches use ~9,000) |
| Weekly | Only videos whose comment count grew since the last fetch (from the daily snapshot); read newest first, stop at the first comment already stored. Expect ~100-300 units |
| Where | New Edge Function `youtube-comments` (same API helper and key secret as `youtube-extras`). It works in chunks of ~100 s (Edge Functions stop at 150 s), saves progress per video, and returns "more to do" |
| Schedule | pg_cron **Tue 11:30, 11:35, 11:40 PH** (extra calls exit at once when nothing is left). Backfill: same function, called every 3 min for about 40 min once |
| Tables | `raw.youtube_comments` (comment_id pk, video_id, fetched_at, comment jsonb), `raw.youtube_comment_fetch` (video_id, fetched_at, count_at_fetch, newest_comment_id, status: ok/disabled/error). View `staging.youtube_comment` |
| Size | ~150k rows ≈ 50-60 MB → DB ~130 → ~190 of 500 MB |
| Edge cases | comments disabled (403 `commentsDisabled`) → status disabled, don't retry; `quotaExceeded` → stop, resume next call |

## Part B: the analysis

1. **One comment table for both platforms.** View `staging.fan_comment` (platform, comment_id, video_id, text, created_at, likes, author_key) = TikTok ∪ YouTube.
2. **Name list.** Table `mart.artist_alias` (alias, spotify_id, source, ambiguous). It's built from Spotify names, NDN names, TikTok handles and `spotify_name_map`, plus a manual stoplist and manual extras (artists fans ask for who aren't in the list yet).
3. **Name hits (insert-only).** Table `mart.comment_artist_hit` (comment_id, platform, spotify_id, own_video). A substring pre-filter, then a whole-word check. This runs in batches of 20k comments, because one 200k × 300-name regex join timed out. Weekly: only new comments.
4. **Candidates** = a hit on another artist's video, or a strong request word ("next", "invite", "guest", "sunod", "balik", "upload", "full version", "spotify"). Expect ~500 on TikTok, ~4-6k on YouTube for the backfill, then ~100 a week.
5. **Labels.** Table `raw.comment_label` (comment_id, platform, label, spotify_id, labeled_by, labeled_at). Labels: `artist_request`, `song_request`, `collab_request`, `upload_request`, `mention_no_ask`, `noise`. Claude reads the candidates in batches of ~300: the backfill in a session, new ones weekly as an extra step in the 15:00 routine. That's free on Vic's plan and needs no API key.
6. **Rule check.** Compare rules-only against the labels (precision: of the comments the rules flag, how many are real requests). If the rules reach ≥ 85%, labels are only needed for unclear ones.
7. **Unknown names.** Candidates with a request word but no known name: list the capitalised words after "si/sina/invite/with", Vic reviews, accepted names go into `mart.artist_alias` (same as the @handles review on 2026-10-20).

### Outputs

- `mart.fan_demand_artist`: per artist, last 12 months. Distinct fans asking (one superfan can't swamp it), requests per 1,000 comments, per platform and combined, already played / cooling down. Feeds Fan demand 15% as a percentile, like the other parts.
- `mart.fan_upload_request`: filmed sessions fans ask NDN to post, with how many fans asked and the latest ask.
- Song requests stay inside artist demand. No song advice (Vic, 2026-10-21).
- Later: YouTube timestamps in comments ("2:15 🔥") vs the most-replayed graph (`raw.youtube_heatmap`). Optional, not in this build.

## Build order (one session each)

1. sql/018 tables + views, Edge Function `youtube-comments`, test on 5 videos, then the backfill on a non-Monday.
2. `artist_alias`, `comment_artist_hit`, candidates; Claude labels the TikTok candidates first (small), then YouTube.
3. Rule check, `fan_demand_artist`, `fan_upload_request`, update `INVITE_SCORE.md`, add the weekly labeling step to the 15:00 routine.

## Exercise for Vic (teaching)

Label 50 candidates yourself (the same 6 labels) before Claude does. Then compare: agreement % = same label ÷ 50. Where you disagree, decide who's right, and write the rule in one line in this file. That's how a labeling guide is made.
