# Top 10 artists to invite: score design (draft 2026-10-20)

Independent analysis of public data, not affiliated with Nine Degrees North.

Goal: each week, rank OPM artists NDN could invite to Live at The Cozy Cove, and show **why** each one ranks there.

## What the research says (how bookers and data firms judge artists)

- **Proof of draw beats size.** Booking agents start from past ticket sales; for acts without ticket data they triangulate from streaming and social numbers ([Water & Music](https://www.waterandmusic.com/how-booking-agents-use-and-dont-use-data)).
- **Where listeners live matters more than the total.** City-level streaming is the most persuasive streaming number for a live show; playlist-driven listeners don't always buy tickets ([Orphiq, booking agents](https://orphiq.com/resources/booking-agent-guide)).
- **Trend beats level.** A steady upward line is more convincing than a big flat one. Chartmetric's "career trend" compares the last 45 days with the 45 before, and compares artists only with others at the same career stage ([Chartmetric](https://hmc.chartmetric.com/chartmetric-artist-career-stage-growth/)).
- **Use relative scores, then weight them.** Chartmetric scores each input 0-1 against all artists, then combines them with fixed weights ([Chartmetric CPP](https://hmc.chartmetric.com/cross-platform-performance-ranking-and-scoring/)). We do the same with percentile ranks.
- **Fan quality, not just reach.** Followers ÷ monthly listeners shows whether listeners become fans; a low ratio means reach without loyalty ([Orphiq, metrics](https://orphiq.com/resources/music-data-metrics-that-matter)). The thresholds in these sources are rules of thumb, not standards.

## The score (0-100)

Every part is a percentile rank (0-100) within this week's candidate pool, so one huge artist can't swamp the rest.

| Part | Weight | Measure (source) |
|---|---|---|
| Momentum | 25% | Spotify PH weekly chart: weeks on chart, best rank, rank change (kworb, have it) + monthly listeners growth over 8 weeks (Spotify page, data set 3) |
| PH local reach | 20% | Listeners in PH cities from the artist's top 5 Spotify cities; Metro Manila + Baguio/North Luzon counted first (data set 3) |
| Fan demand | 15% | Distinct fans asking NDN for the artist (artist, collab, song or upload requests) in YouTube + TikTok comments, last 12 months, per 1,000 comments: `mart.fan_demand_artist.fans_per_1000_comments` (built 2026-10-21, `FAN_REQUESTS.md`). Instagram comment text is Phase 2 |
| NDN track record | 15% | Artists who played: median TikTok performance index + YouTube performance index, size-adjusted, and share of current YouTube views (have it; defined in `YOUTUBE_QUESTIONS.md` Q13). Later: Spotify lift after a session (Q12). New artists get 50 and a "new" tag |
| Size | 15% | Monthly listeners, log scale (data set 3) |
| Fan loyalty | 10% | Spotify followers ÷ monthly listeners (data set 3) |

Why these weights: momentum and local reach get the most because the decision is "who draws a Cozy Cove crowd and NDN views soon". Size is kept low on purpose: big names already get booked and cost more. Track record is only 15% so new artists can compete.

Rules:
- Candidates = artists in the Spotify PH top 200 in the last 8 weeks + every artist who has played for NDN (OPM only; Vic checks unclear ones).
- **Cooldown 10 months (Vic, 2026-10-20):** an artist who performed is not recommended again until 10 months after the performance. Performance date = first NDN post of the artist's latest visit (a new visit = posts more than 60 days after the previous one; the session is filmed before it goes up, so this date is a little late, never early). They are listed separately as "cooling down until <date>".
- Songs not posted yet: NDN has not posted every song an artist performed, so a missing NDN song never counts against an artist (matching or scoring).
- The table shows each part as a small bar so the reason is visible, not just the total.
- Missing: fee and availability (not public). Once NDN shares ticket sales, add a "draw" part and lower Size and Momentum.
- Check after 8 weeks: do the weights put artists NDN actually booked near the top? If not, adjust and note why here.

## Built 2026-10-21 (`sql/025_invite_score.sql`, view `mart.invite_candidates`)
- Pool = the 279 artists with a Spotify artist page (mostly NDN performers + 39 PH chart artists); only 10 are new to NDN, so the list leans to past guests. PH chart artists without a Spotify page are not scored yet.
- Momentum uses the best Spotify PH weekly rank in the last 8 weeks only (1 chart week so far); monthly-listener growth joins after 8 weekly snapshots.
- Local reach: Metro Manila cities + Baguio count fully, other PH cities half (Spotify top-5 cities only).
- TikTok: the artist's own TikTok followers (91 matched accounts) and TikTok fan asks are shown beside the score, not weighted in it.
- Power BI page "Who to invite": top 10 recommended (score + parts as data bars), the raw numbers behind them, and the cooling-down list.

## New-hit rule (Vic 2026-10-22)
The point of an invite is a live clip of the song people are streaming **now**. So, whatever the score:
- **Gate:** recommended only if one of the artist's top 5 Spotify songs (daily streams, kworb) is **not on NDN's YouTube** and came out **after their latest NDN visit** (new artists: last 12 months; unknown release date: total ÷ daily streams < 365). Otherwise "Not now" (hit already on NDN, or no new hit since the visit). Cooldown still applies first.
- **New weights:** new-hit hype 25 (percentile of the new hit's daily streams among artists that have one), momentum 20, local reach 15, fan demand 10, track record 10, size 10, loyalty 10.
- First result (2026-10-22): 39 recommended; top 3 Le John ("Alanganin"), Rob Deniel ("Nandito Ako", 142k/day), DENȲ ("Alam Ko Na", 348k/day). Cup of Joe, Orange & Lemons: high scores but their hits are already on NDN.
- Limits: kworb lists songs only for 127 of 279 artists (the rest show "No song stream data"); release dates come from the Deezer catalog (80% of songs matched).

## Built 2026-10-22: TikTok first (`sql/026_tiktok_first.sql`, same view `mart.invite_candidates`)
- **Artist sounds:** `extract_tiktok_extras.py --steps artist_videos` lists each artist account's latest 30 videos with yt-dlp (the headless-browser profile page returns an empty video list; yt-dlp drops the sound id, so its parser is wrapped to keep it) → `raw.tiktok_artist_video`. A song counts only when its sound is a released (not "original sound") track credited to the artist (`staging.tiktok_artist_sound`); sped-up/single versions merge by title. `artist_sounds` then counts "videos using this sound" weekly → `raw.tiktok_sound_stats` (same table as NDN's sounds), growth in `staging.tiktok_sound_growth`.
- **Finding artists' TikTok accounts:** listed by Vic > tagged in NDN captions > the artist's Instagram username tried as a TikTok handle, kept only when the display name contains the artist's name, or the handle does AND the account posts the artist's released songs (`staging.artist_tiktok_account`; `@hev.abi` is "LS Dreams", so the check matters). First run: 47 found this way → 149 artists with a TikTok account (was 102). Missing or wrong guesses are retried after 30 days.
- **Release date when Deezer has none:** the TikTok sound's id holds its creation time; for 3 Rob Deniel songs it was ~2 weeks before the Deezer release, so it can only make a song look older, never newer.
- **Viral 50 PH replaced:** Spotify's "Viral 50 - Philippines" chart playlist doesn't come up in Spotify search (2026-10-22); Spotify's own editorial **"Viral Hits Philippines"** (100 songs) stands in, read weekly (`extract_spotify.py --steps playlists` → `raw.spotify_playlist_snapshot`). It and the PH weekly chart only **add candidates** (`found_via`), not points. Candidates who never played for NDN need ≥ 90% PH listeners in their Spotify top 5 cities (OPM check; 258 of 272 NDN artists are at 90%+, while at 50% Boyz II Men and Leona Lewis got in); under 30% are not refreshed after the first look. First run: 160 new candidates (123 chart, 37 Viral Hits), 77 pass. **Vic to check:** Nick Jonas, Edwin McCain, Stephen Speaks (US acts) and groundZERO Records (a label) still pass; switch off with `update raw.spotify_artists set active = false where name in (...)`.
- **Weights as approved** (TikTok 55 / Spotify 30 / other 15). The new song = the artist's new, not-on-NDN song with the most TikTok videos (then Spotify streams). Column names kept from sql/025 so Power BI keeps working: `new_hit_hype` is now the Spotify-streams part (15), `track_record` the NDN TikTok record (5); `loyalty` is shown, not weighted. New: `tiktok_points`, `spotify_points`, `other_points`, `tt_song_videos`, `tt_song_growth`, `tt_follower_growth`.
- **Fixed on the way:** sql/025 read "the latest snapshot date" over all artists; once new candidates are read on another day that drops everyone else. Now each artist's own latest Spotify / kworb snapshot (last 14 days).
- **Growth parts are 0 for everyone until the second weekly count** (sound and follower growth need two counts ≥ 6 days apart): first growth on Mon 2026-10-26, a fair 4-week figure from 2026-11-16.
- **Schedule:** `weekly.yml` job `tiktok-artists` (Mon 10:30 PH, beside the main TikTok job, own 120-min limit); `spotify.yml` now starts with `playlists`.

## TikTok-first plan (Vic 2026-10-22, APPROVED incl. weights + GitHub Actions push; built 2026-10-22, see above)
Vic: rank on TikTok first, Spotify second; only real artists' songs that NDN can film (no AI/meme sounds without an artist); check how TikTok converts to YouTube views.

**Evidence on conversion**
- Own data (347 NDN songs on both platforms, real latest counts): NDN TikTok clip views vs the same song's YouTube session views, log-log r = 0.62 (slope 0.82). Median 7.1 YouTube views per TikTok view; by TikTok tier the median session gets 61k (<10k TikTok), 265k (10k-100k), 1.6M (100k-1M), 8.6M (1M+) YouTube views. Correlation, not proof: a popular song lifts both.
- Research: TikTok's effect on chart life is stronger for YouTube and Shazam than for Spotify (2026 cross-platform study, ideas.repec.org/p/cue/wpaper/awp-06-2026.html); losing TikTok cut Spotify demand mainly for viral songs (UMG withdrawal, arXiv 2405.14999). Industry claims (TikTok/Luminate: 84% of 2024 Global 200 entries took off on TikTok first) are not independent.
- Sources ruled out: Tokchart PH chart needs a login and its terms forbid showing the data in a dashboard; TikTok Creative Center songs list is gone (2026-10-19).

**New data (free, our own extractor)**
1. `extract_tiktok_extras.py --steps profiles`: also keep each artist account's recent videos with their sound (music id, title, author, "original" or catalog). Artists post their own songs, so this finds each song's official TikTok sound. Only catalog sounds credited to the artist count, which drops AI/meme/no-artist sounds.
2. `sounds` step: weekly "videos using this sound" for those sounds → TikTok trend size + 4-week growth (dances and trends all show up as videos on the sound).
3. Spotify Viral 50 Philippines (social-driven chart) via the existing Spotify extractor, weekly, as a second pool of candidates.
Runs in GitHub Actions `weekly.yml` (TikTok blocks the home IP) → needs a push, ask Vic first.

**Proposed weights (gate unchanged: the song must be new and not on NDN's YouTube)**
TikTok 55: new song's TikTok videos 25 · its 4-week TikTok growth 15 · artist TikTok follower growth 10 · NDN TikTok track record 5.
Spotify 30: new hit daily streams 15 · PH chart momentum 10 · local reach (Manila + Baguio) 5.
Other 15: fan requests 10 · size 5.
Also in that build (Vic 2026-10-22): hover help on every column (source + meaning, as field descriptions + an "i" header tooltip per visual) and plain-language column labels for non-analysts.
