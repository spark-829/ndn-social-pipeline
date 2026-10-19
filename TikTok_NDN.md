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
- Schedule (pg_cron, PH time): Monday 10:00 trends (`ndn-music-trends-weekly`); Monday 10:10-11:50 every 10 min Deezer (`ndn-music-deezer-weekly`, budget 500 requests a call, returns "finished" when nothing is left).
- Tables: `raw.trend_responses`, `raw.deezer_search`, `raw.deezer_track_search`, `raw.deezer_artist_albums`, `raw.deezer_album_tracks`, `raw.music_runs` (run log), `raw.music_artist_override` (Vic's fixes). Views: `staging.trend_tiktok_hashtag`, `staging.trend_spotify_ph`, `staging.trend_spotify_ph_ndn`, `staging.ndn_artist_credit`, `staging.deezer_artist_match`, `staging.ndn_artist`, `staging.music_release`, `staging.music_track`, `staging.music_catalog_status`.
- Artist matching: names come from NDN's YouTube titles (TikTok/IG artist fields are too noisy); collaborations are split ("Dionela ft. Loonie") only when the full credit has no exact match (so "Ben & Ben" stays whole). Match order: Vic's override → **confirmed by song** (Deezer search "<artist> <a song NDN posted>" returns that artist) → exact name → partial name (not used, listed for checking). Deezer merges some same-name artists into one profile (Kaia, Carlo, Penelope), so their catalogs can include other people's releases.
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
