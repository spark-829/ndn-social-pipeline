# TikTok and NDN: how posts follow the shows

Independent analysis of public data, not affiliated with Nine Degrees North.
Context from Vic, 2026-10-18. Use this note when rebuilding the TikTok dashboard.

## The pattern

1. **About 1 week before a live show**, NDN posts an announcement: date, venue, ticket link, artist lineup. Example: the post for Live at The Cozy Cove on 24 Oct 2026 (Mountain Lodge, Baguio) with APO Hiking Society, Shamrock, Kyle Raphael and Noodlez.
2. **The lineup mixes two kinds of artists:** ones trending right now, and older, well-known ones.
3. **After the show**, the most trending or best-known song from the set is uploaded first, as soon as possible. Other songs follow later.

## What this means for the dashboard

The dashboard should help answer two decisions: **which artists to invite** and **what to post first after a show.**

- **Invite:** compare artists by their TikTok performance index on NDN (views ÷ median of NDN's 30 posts nearest in time), split into "trending now" vs "older popular" artists. Does each kind pull its weight on TikTok, and which brings followers?
- **Post first:** check whether the first song uploaded after a show really is the best performer of that set. If a different song from the same show does better, the "upload the biggest song first" rule needs adjusting.
- **Timing:** measure the gap between the show and each upload, and whether faster uploads do better (the buzz from the show fades).
- **Announcements:** measure how announcement posts perform, and whether the lineup in them affects their reach.

## Data needed

- Show dates and lineups: parse the announcement captions (full captions now come from `extract_tiktok_details.py`, table `staging.tiktok_video_details`).
- Song and artist per clip: the title parser (`mart.parse_title`), the sound name, and hashtags (song and artist tags such as `#esremborak`, `#andrejagas`).
- Clip type (announcement, performance, interview such as `#ndnterviews`): from caption + transcript, checked by Vic.
- "Trending now" vs "older popular": TikTok Creative Center PH trends (Q16) and Spotify streams from kworb (Step 4).

## New data set: trends and artist catalogs (planned 2026-10-18)

Goal: suggest, for each day or week, **which NDN clip to post or which YouTube session to boost** because the song or artist is trending now. Kept as its own data set (own schema, e.g. `music`), separate from the daily NDN snapshots.

**Built 2026-10-19** (`sql/013_music_trends.sql`, `013c_music_song_check.sql`, Edge Function `music-weekly`). What we found and what runs:
- TikTok Creative Center was rebuilt (new address `ads.tiktok.com/creative/creativeCenter/trends/...`). **The songs list is gone**: every song/music URL redirects to hashtags. The new hashtag API (`CreativeOne/KnowledgeAPI/GetHashtagList`) answers a plain request, no signing and no browser needed (Playwright tested, not needed). Logged out it gives only the **top 3** per list; "View more" needs a login, which we don't do. Workaround: 19 industry filters, each with its own top 3 (23 = News & Entertainment) → 20 lists, 60 PH hashtags a week.
- Trending songs therefore come from **kworb's Spotify Philippines weekly chart** (top 200, chart dated Thursdays).
- **Deezer filters its catalog by the caller's country.** From Supabase's servers (Seoul) Lola Amour has 3 releases; from the Philippines, 33. So Deezer runs from the **home server** (PH IP): `~/ndn_music/extract_music_catalog.py` (stdlib Python, same 2-key `.env` as `~/ndn_tiktok`) asks `music-weekly?part=deezer_todo` what to fetch, calls Deezer, posts replies to `?part=deezer_save`. Steps: search names → song check → release lists (refetched after 6 days) → track lists of new releases.
- Schedule (PH time): Monday 10:00 trends (pg_cron `ndn-music-trends-weekly`); Monday 10:10 Deezer (server cron, log `~/ndn_music/logs/weekly.log`; crontab backup `~/crontab_backup_2026-10-20.txt`). The pg_cron job `ndn-music-deezer-weekly` from the first test is switched off. If the server is off on a Monday, nothing breaks: the next run catches up. Copy the script to the server again if it changes.
- Tables: `raw.trend_responses`, `raw.deezer_search`, `raw.deezer_track_search`, `raw.deezer_artist_albums`, `raw.deezer_album_tracks`, `raw.music_runs` (run log), `raw.music_artist_override` (Vic's fixes). Views: `staging.trend_tiktok_hashtag`, `staging.trend_spotify_ph`, `staging.trend_spotify_ph_ndn`, `staging.ndn_artist_credit`, `staging.deezer_artist_match`, `staging.ndn_artist`, `staging.music_release`, `staging.music_track`, `staging.music_catalog_status`.
- Artist matching: names come from NDN's YouTube titles (TikTok/IG artist fields are too noisy); collaborations are split ("Dionela ft. Loonie") only when the full credit has no exact match (so "Ben & Ben" stays whole). Match order: Vic's override → **confirmed by song** (Deezer search "<artist> <a song NDN posted>" returns that artist) → exact name → partial name (not used, listed for checking). Deezer merges some same-name artists into one profile (Kaia, Carlo, Penelope), so their catalogs can include other people's releases.
- **First real run (2026-10-19/20):** trends from pg_cron path: 20 TikTok lists, 60 PH hashtags, 200 kworb rows (chart 2026-10-15). Deezer from the server: 8,714 requests in 21.5 min, 349 names searched, 349 song checks, 247 Deezer artists for 278 of 309 NDN credits, 7,948 releases. Match types: 182 confirmed by song, 57 exact, 14 exact-but-shared-name (check), 7 partial (not used), 87 none, 3 manual. **88% of NDN's posted YouTube songs (617/703) are found in the catalogs.** Song labels: 531 posted, 11,773 released before NDN's last visit but not posted, 2,974 released after. 66 of the week's Spotify PH top 200 rows are by NDN artists (15 in the top 50, e.g. #3 Esremborak "Mahal Magmahal", #17 Cup of Joe "Multo"). Second run (incremental) fetched only what changed: 10 requests.
- Caveats: "before last visit" is inflated by intros, interludes and live versions on albums, and by merged same-name profiles (Lynx 444 releases, Kaia 210, Carlo 194; check these). A "visit" is a stand-in: a run of YouTube uploads with no gap over 60 days, not the real show date. LILY = formerly Callalily (override set; the old songs sit under Callalily, Deezer 173744).
- Manual fix: `insert into raw.music_artist_override values ('<name_key>', <deezer id or null>, '<note>');` (name_key = lower case, letters/digits only).

**A. Trending songs in the Philippines (mainly OPM)**
- ~~TikTok Creative Center, Top songs~~ (removed by TikTok, see above). Hashtags only, top 3 per list.
- Spotify Philippines weekly chart on kworb (free); full kworb work stays in Step 4.
- Mark each trending song as OPM or not: artist country/genre from Deezer/MusicBrainz, then Vic checks the unclear ones.

**B. Every Cozy Cove artist and their full catalog**
- Artists: from NDN's posts (TikTok captions, hashtags, title parser; YouTube titles `Song (Live at The Cozy Cove) - Artist`), each with the date(s) they performed.
- Catalog: Deezer API (free, no key), tested 2026-10-18: Kyle Raphael 18 releases (2019-06-28 to 2026-09-18), Esremborak 4, Dionela 22, with release dates. MusicBrainz as the fallback for artists Deezer lacks.
- For each artist and performance date, every song is labelled:
  - **performed and posted** (on NDN TikTok and/or YouTube),
  - **released before the show but not posted** (could have been in the set: candidates for a later clip),
  - **released after the show** (couldn't have been performed then).

**C. How the suggestion works later**
- A trending song (A) by a Cozy Cove artist (B) that NDN already has on YouTube → suggest boosting that YouTube video and posting a TikTok clip of it.
- A trending song by an artist who performed but whose song wasn't posted → ask whether NDN has unused footage.
- A trending artist who hasn't performed yet → candidate to invite.

## Questions this adds (see TIKTOK_QUESTIONS.md)

- Which invited artists bring the most views and followers to NDN on TikTok, adjusted with the performance index?
- Do trending-now artists beat older popular artists on TikTok, or the other way round?
- Is the first song uploaded after a show the best performer from that show?
- Does a shorter gap between show and upload mean more views?

## TikTok extras (built 2026-10-20, weekly)

`extract_tiktok_extras.py` → Edge Function `tiktok-extras` → `raw.tiktok_video_page`, `raw.tiktok_sound_stats`, `raw.tiktok_comments` (+ `raw.tiktok_comment_fetch`), `raw.tiktok_accounts` (list), `raw.tiktok_account_snapshot`; views in `sql/014_tiktok_extras.sql`. Runs Mondays 10:30 PH on GitHub Actions (`.github/workflows/weekly.yml`, "Run workflow" button has steps + limit inputs). Run log: `raw.music_runs` where part = 'tiktok_extras'.
- How each part is fetched: video page = yt-dlp's own page reader (plain requests get a 1.4 KB challenge page); sound page and profiles = headless Chromium (the numbers load by JavaScript; also gets past the home-IP block on profiles); comments = TikTok's web comment list with Chrome TLS (works unsigned). Tested from Vic's PC and from GitHub (all 4 steps OK).
- "shares" in our snapshots = TikTok shareCount (yt-dlp calls it repost_count). TikTok's own repost count is `staging.tiktok_video_page.reposts`.
- Artist accounts: found from NDN's @tags when the handle contains the artist's name (43 of 69 tagged handles at first count); others (e.g. @anqelaken = Angela Ken) need a row in `raw.tiktok_accounts` (role 'artist', artist_name_key). Benchmark accounts: rows with role 'benchmark' (so far `wish1075official`, from wish1075.com).
- First run: PC backfill 2026-10-20 03:04-04:00 PH (980 video pages, 950 of 955 sounds, comments for 6 videos), stopped so Vic could turn the PC off; GitHub run 39315979394 (started 04:02 PH) does the rest (about 48,000 comments + profiles). Early finds: "Panalangin" (Apo Hiking Society) sound used in 43,900 videos; NDN original sounds in 1-2 each; 894 of 955 sounds are NDN originals.
