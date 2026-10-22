# Plan: find trending OPM sounds from TikTok itself

## Context
Today "trending" = the **all-time** "videos using this sound" count for songs posted by artists **already in our pool**
(354 OPM artists from NDN, Vic's list, Spotify PH chart, Viral Hits PH). Live data 2026-10-22: only 96 of 354 artists
have a TikTok count for their new song, 167 have no TikTok account found, old hits outrank songs hot this week, fan
sped-up/remix sounds are dropped, and a sound blowing up from an artist outside the pool is invisible.

**Proof case (Vic, 2026-10-22): Mariah Deborah "Na Para Bang".** #1 on the Spotify PH chart, 1.6M plays/day, yet
only #14 among "Recommend" (score 37.3): Spotify 29.9/30 but TikTok 2.5/55. Her latest 30 TikToks have no official
"Na Para Bang" sound, and the sounds people actually use (TikTok search, Sounds tab: 1.3M, 282K, 197K, 166K, 145K...
videos) are fan uploads labelled "Contains music from: Na Para Bang", which our "credited to the artist" rule drops.

Vic's decisions (2026-10-22):
- **Trending = videos added to the sound in the last 7 days** (growth % only as tiebreak).
- **Discovery mostly from TikTok:** the sounds used most in recent PH music videos, kept only if viable for NDN
  (a real song by a real OPM artist NDN could invite).
- **Fan versions count** when the sound title names the song (sped up, slowed, remix, etc.).

## Approach
### Step 0: feasibility test from Vic's PC (one short session, no DB changes)
yt-dlp's hashtag and sound-list readers are marked broken (`_WORKING = False`), and Creative Center's songs list is gone.
Test all, keep what works (no logging in to TikTok, ever):
A. **Song search (fixes Mariah):** headless browser opens TikTok web search for "Na Para Bang", Sounds tab, and
   catches the search reply. Check: does it list the sounds with video counts, and does each sound carry the
   "Contains music from" song (title + artist id)? If yes, that field ties fan uploads to the real song.
1. Headless browser (existing `Browser` in `extract_tiktok_extras.py:130`) opens `tiktok.com/tag/<tag>` and catches the
   `/api/challenge/item_list/` replies. Each video carries `music {id, title, authorName, original}` + create time.
2. The same for a sound page's video list (`/api/music/item_list/`), to snowball from known OPM sounds.
3. Re-probe Creative Center's PH song ranking (the hashtag API in `music-weekly` still works, so try its sibling).
Pass mark: 100+ videos from the last 7 days per tag, with their sound ids. If all three fail: report back before building.

### Step 0 results (2026-10-22) and new direction (Vic)
- No login: search + hashtag lists come back empty; sound pages + their video lists work.
- Vic's 1.3M "Na Para Bang" sound is "original sound - tiwa" on the web, no song link (`tt2dsp` empty); only the
  app shows "Contains music from". Captions of its videos name the song (#naparabang, #mariahdeborah) in 9 of 57,
  Tagalog is the top caption language. So songs are tied to fan sounds by **caption vote**, whatever the route.
- Creator crawl rejected (Vic: fan sounds come from random one-off creators).
- **Route = dummy TikTok account, logged in on the home server** (runs when the PC is off). Set up 2026-10-22:
  `~/ndn_tiktok_search` (uv venv + Playwright, uses the server's Google Chrome, profile in `profile/`, never in git);
  `login.sh` (Vic runs it over Remote Desktop and logs in himself), `probe_search.py` (test over SSH).
  Copies in `Home_Server/ndn_tiktok_search/`. Slow pace, stop on captcha, dummy account only.

### Step 0 round 2 (2026-10-22, logged in as the dummy account, state.json on the server)
- Logged-in **general search works** (page's own request): "na para bang" → 16 videos; the most used sound among
  them is Vic's 1.3M "original sound - tiwa" (3 of 16), all captions naming the song. (`probe4.py`)
- Still empty logged in: Videos-tab search, hashtag pages (`/api/challenge/item_list`), page-fetched item search.
- Sound search `/api/search/music/full/` works with the page's own settings (`probe3.py`) and carries
  `matched_song`, but only returns sounds whose own title is the song (covers, library tracks), never fan
  "original sound" uploads. Mariah Deborah's "Na Para Bang" is not in TikTok's library at all.
- **Method = song search (logged in) → sounds its videos use → sound page (no login): video count + ~57 captions
  → caption vote → sum the sounds that vote for the song.** Hashtag discovery is out; TikTok-first discovery =
  a few generic searches ("opm", "opm 2026", "tagalog song"...) whose top sounds go to the review list.
- Load: logged-in searches only (~150-400/week), slow (30-60 s apart, spread over days), stop on captcha.

### Discovery source: TikTok's AI assistant Tako (Vic's proposal, 2026-10-22)
- Weekly, Vic asks Tako (app: Search → Ask) for the 50 OPM songs used most in new PH videos in the last 7 days,
  with the most-used sound name, and pastes the text answer. Prompt kept in this file's appendix.
- Tako's list = candidates only (an AI answer can be wrong); each song is verified by Step 1a + caption vote,
  "recent" (release date or the sound id's creation time) and "trending" (week 1: share of search-result videos
  posted in the last 7 days; from week 2: videos added to its sounds in 7 days). Songs failing a check are dropped;
  non-OPM go to the review list. Score Tako's hit rate for a few weeks; if useful, test reaching Tako from the web
  on the server so it runs without Vic.

### Step 1a: song search, every week — runs on the home server, logged in
- For each candidate song (each pool artist's top 5 Spotify songs + new song, every song on the Spotify PH chart and
  Viral Hits PH, and songs found in Step 1b): search TikTok Sounds for "<song> <artist>", keep every sound whose
  "contains music from" song matches (or, if that field is missing, title match + artist check), and add their
  ids to the weekly sound counts. ~1,500 searches/week; spread over the week if TikTok slows us down.
- New raw table `raw.tiktok_sound_search` (snapshot_date, query, payload); new step `song_search` in
  `extract_tiktok_extras.py`.

### Step 1b: collect a weekly sample of PH music videos (TikTok-first discovery)
- New raw table `raw.tiktok_tag_video` (snapshot_date, tag, video_id, author, posted_at, views, music jsonb).
- Tags = a fixed OPM list (#opm, #opmsongs, #pinoymusic, #opmhits, ... Vic can edit) + this week's PH music hashtags
  already collected in `raw.trend_responses` (`music-weekly`, Creative Center top hashtags, PH).
- New step `tag_videos` in `extract_tiktok_extras.py` (same `Feed`/`run_step` pattern) + todo/save branch in the
  `tiktok-extras` Edge Function. Runs in GitHub Actions `weekly.yml` job `tiktok-artists` (Mon 10:30 PH), since
  TikTok blocks the home IP. **Needs a push, ask Vic first** (GitHub Actions rule).

### Step 2: tally and filter the sounds (new `sql/028_tiktok_trending_sounds.sql`)
- `staging.tiktok_sound_usage`: per sound, the different videos and creators in the last-7-day sample = "most used".
- **Song matching:** strip version words (sped up, slowed, reverb, remix, nightcore, 8D, "x"...) from the sound title,
  then match title + artist name with `staging.name_key` against our songs (Deezer catalogs, Spotify/kworb, existing
  `staging.tiktok_artist_song`, which already groups versions by title key).
- **Viability filter**, each sound gets one label:
  - `ok`: matched to a song by an artist passing the OPM check (`staging.spotify_artist_ph_share` >= 90%, or an NDN artist)
  - `new artist?`: names a song/artist we don't know yet → looked up on Spotify (existing `extract_spotify.py`)
    so the OPM check can run next week
  - `drop`: original sound with no song in the title, non-OPM artist, meme/AI/no artist
  - `review`: anything unclear, listed for Vic
- Discovered `ok` sounds join the weekly sound counts (`artist_sounds` todo in `tiktok-extras`, existing
  `Browser.sound` reader → `raw.tiktok_sound_stats`).

### Step 3: "trending" number and the invite score
- `staging.tiktok_song_trend`: per song, sum over all its sounds (official + fan versions) of
  **videos added in the last 7 days** = latest count − count ~7 days earlier, scaled to 7 days (same scaling rule
  as `staging.tiktok_sound_growth`), plus growth %.
- Caveat to show in hover help: TikTok rounds big counts ("2M"), so weekly gains for huge sounds are coarse; the
  sample count from Step 2 backs it up.
- `mart.invite_candidates`: part `tt_song_videos` (25%) switches from total videos to weekly new videos;
  `tt_song_growth` (15%) stays. Artists found only through TikTok join the pool once they pass the OPM check
  (`found_via` = 'TikTok trending').

### Step 4: dashboard
- `export_powerbi.py`: new export `tiktok_trending` (song, artist, weekly new videos, growth, videos in sample,
  versions counted, label, on NDN yet?).
- `build_powerbi.py`: "Trending OPM sounds this week" table on the Who to invite page + a small `review` list;
  labels/help added in `powerbi_labels.py` (the build stops otherwise).

## Files
- `NDN_Social_Pipeline/extract_tiktok_extras.py` (step `tag_videos`, reuse `Browser`, `Feed`, `run_step`)
- `NDN_Social_Pipeline/supabase/functions/tiktok-extras/index.ts` (todo + save for `tag_videos`, discovered sounds in `artist_sounds`)
- `NDN_Social_Pipeline/sql/028_tiktok_trending_sounds.sql` (new), `mart.invite_candidates` (from sql/026)
- `.github/workflows/weekly.yml` (add the step to job `tiktok-artists`)
- `export_powerbi.py`, `build_powerbi.py`, `powerbi_labels.py`, `INVITE_SCORE.md` (document the new rule)

## Timing
- Weekly new videos need two counts ≥ 6 days apart: songs already counted get it on Mon 2026-10-26; newly
  discovered sounds one week after they are first found.

## Verification
1. Step 0: the test script prints videos per tag, share with a sound id, newest posted date; and for
   "Na Para Bang" the sounds found, their video counts and the "contains music from" field.
1b. Mariah Deborah check: after the rebuild her TikTok points rise well above 2.5 and "Na Para Bang" shows
   ~2M+ videos summed over its versions.
2. After the first run: `select count(*), count(distinct music->>'id') from raw.tiktok_tag_video where snapshot_date = current_date`.
3. Top 20 of `staging.tiktok_sound_usage` with labels: Vic eyeballs that the `ok` ones are real OPM songs.
4. Spot-check 3 songs: weekly new videos match the sound pages' counts a week apart.
5. Rebuild Power BI: `py build_powerbi.py` + `py powerbi/tools/validate_pbir.py powerbi` pass.

## Appendix: Tako prompt (paste in TikTok app, Search → Ask)
List the 50 songs by Filipino artists (OPM) that were used most in new TikTok videos in the Philippines in the last 7 days. Leave out foreign songs, meme sounds and AI voices. For each song give: song title, artist, and the name of the sound most people use for it (as it appears on TikTok, e.g. "original sound - name" or "Song (sped up)"). Answer only as a numbered list: Title - Artist - Sound. No explanations.

## Tako trial (2026-10-22, `Home_Server/ndn_tiktok_search/verify_tako.py`)
Tako's 50: #1-16 plausible, 4 not OPM (Olivia Rodrigo, Ashe, ADÉLA x2), 19 filler lines "(Original OPM Track) - OPM
Artist", many years-old classics; every sound name a template ("original sound - <artist>"), i.e. made up.
Checked 4 before TikTok throttled logged-in search (~4 searches in 2 min, then empty replies; fresh tab per song helps
but is not enough): Na Para Bang 7 of 13 search videos from the last 7 days, top fan sound 166K (trending);
Mahal Magmahal 3/15, sound from Jan 2025; Edi Magalit Ka 1/14, sound 37 videos; Mga Kababayan 0/13, sound 1,609.
So: Tako = candidates only; checks decide. **Weekly job pace: one song every 3-5 min, overnight on the server
(~100-150 songs/night).** Next: re-run the other 9 later at that pace, then build Step 1a.

## Round 6 (2026-10-22 night): Vic: "the invite sheet is top priority, find a method that works; idea: Spotify trending → TikTok Sounds tab"
- **Tako re-check, other 9 songs, 3-5 min apart:** OT Na Naman (0 of 12 new in 7 days, sound 287 videos), Sino (0/15,
  sound 23K), then Baby 123 and Isang Pag-Ibig came back **empty**. Logged-in search page loads are capped per
  account (2-4 a session), not just rate-limited. Stopped; 5 not checked. Tako stays candidates-only.
- **Creative Center songs: gone for good.** The trends page's code has only Hashtag, Creator and Video tabs; old
  `creative_radar_api` = "no permission"; `KnowledgeAPI/Get*SongList` 404. Apify actors claiming sound charts are stale.
- **Explore page (no login):** works but ~26 mixed videos, 2 from the last 7 days. Too thin for discovery.
- **NEW SOURCE that works: YouTube Charts "Top songs on Shorts", Philippines** (daily + weekly top 50, ranked by
  number of Shorts *created* with the song = YouTube's twin of TikTok's "videos using this sound"). Plain POST, no login:
  `charts.youtube.com/youtubei/v1/browse?alt=json`, client WEB_MUSIC_ANALYTICS 2.0, browseId
  FEmusic_analytics_charts_home, query `flags=MusicCharts__enable_apac_and_shorts_charts_expansion&perspective=CHART_DETAILS&chart_params_country_code=ph&chart_params_chart_type=SHORTS_TRACKS_BY_USAGE&chart_params_period_type=DAILY|WEEKLY`.
  2026-10-22 daily: mostly global meme audio; OPM = Na Para Bang 11, Puede Nang Mangarap 12, Bangon Pilipinas 14,
  Sayaw (Maan Chua) 25, Baby 123 27. Fits `music-weekly` (Edge Function, plain fetch).
- **Vic's idea, tested:** candidates = OPM songs (Spotify PH share >= 90%) on today's kworb PH daily top 200 (126) +
  Viral Hits PH (29 more) = 155. `spotify_to_sounds.py` (server, logged in): one search page load, then
  `/api/search/music/full/` fetched inside the page ~1/min. **Not capped** (155 songs in one run).
  Loose title matching pulls in other songs with the same title (Ikaw Lang 17 sounds, Star Song → Lil Durk).
- **Caption vote built** (`caption_vote.py`, PC, no login, sound page video list): a sound counts for an artist if
  TikTok credits the artist, else if 2+ captions name the artist. Na Para Bang: Vic's 1.3M "original sound - tiwa" 4/57
  name Mariah ✔; "Na Para Bang" by *Alexander Miller* 11/57 ✔ (re-upload); "Na para bang" by Liel 0/32 ✘ (other song).
  `build_review_list.py` applies it and adds the YouTube Shorts rank.
- **Still missing: fan "original sound" uploads** (Na Para Bang's real volume). Only general search finds them, and its
  page loads are capped. `probe5.py` tests general search fetched inside the open page (queued after the run).
- Next: `recount_sounds.py` ~24 h after the first count (PC, no login) → new videos per day per song = the trending
  number; then Vic checks the review list by hand before anything goes into the invite score.

## Research 2026-10-23 (Vic: "research intensively, top priority of the pipeline")
### Rules found (robots.txt, read 2026-10-23)
- **tiktok.com blocks AI agents by name** (ClaudeBot, Claude-User, Claude-SearchBot, anthropic-ai, GPTBot...: Disallow /).
  So Claude does not fetch TikTok itself any more (stopped the caption-vote job mid-run, 290 of 415 votes saved).
  Generic bots (`*`): allowed /music (sound pages), /foryou, /discover, /tag; **disallowed /search?** (so the logged-in
  search method breaks the rules for every bot: dropped). Vic's own scheduled pipeline = his crawler, generic rules.
- ads.tiktok.com (Creative Center): `Allow: /` for all, Claude included. kworb, Shazam, Chartmetric, Songstats, Exolyt,
  Tokchart: allowed. charts.youtube.com: `/youtubei/` disallowed (the Shorts chart data) → human viewing only.
  Spotify charts service (`charts-spotify-com-service`): Disallow / → Viral 50 PH only as Vic's manual CSV download.
### What exists, tested
| Source | Result |
|---|---|
| Creative Center songs | gone (page code: hashtag/creator/video tabs only) |
| Creative Center top **videos** (`GET /CreativeOne/Report/CreativeCenterGetTopContentsList`, periodDimension 1 weekly / 3 last-7-days-created, orderByMetric 1 views, countryCode PH) | answers but empty without login; overview `GetTopContentsOverview` = "InvalidLogin" → **needs a free TikTok for Business login (untested)** |
| TikTok Discover sounds (`/api/discover/music/`) | frozen list from early 2022 |
| TikTok topic pages `/discover/<topic>` | 0-3 random videos |
| Song entity ("Contains music from") on web | `matched_song.id` exists, but no web page/API ("Couldn't find this sound") → app only |
| Logged-in search | capped 2-4 page loads per session + robots-disallowed → dropped |
| YouTube audio page `/source/<id>/shorts` | "9.3K Shorts" for Na Para Bang (robots-allowed path; YouTube ToS limits automation) |
| YouTube Data API search (Shorts, PH, last 7 days) | official; `totalResults` unreliable (Kathang Isip ~37K estimated, 3 real) → only usable as a 24 h page count |
| TikTok Research API | not for PH / non-academic / commercial users |
| Paid: Tokchart Business $59/mo (country filter, "Matched song", "Find UGC using copyrighted songs"), Chartmetric $40+/mo (TikTok top tracks by country), Exolyt ~$400/mo | not free (Vic: no paid subscriptions) |
### Recommended design (3 layers)
1. **Candidates, automatic:** kworb Spotify PH daily (OPM, rising 7-day streams, new entries) + Viral Hits PH + pool new
   releases (all existing) + Creative Center logged in, if the test passes (top PH videos of the last 7 days → their
   sounds; top 100 PH hashtags → song-title hashtags).
2. **Sounds per song, seeded once:** tonight's 155-song Sounds-tab data (official sounds, already collected) + Vic in the
   app, ~5-10 min/week: for each new top-10 candidate, copy the links of its top 1-3 fan sounds ("Contains music from")
   into a sheet. The weekly job's caption vote (sound pages, allowed path) confirms each pasted sound.
3. **Trending number, automatic:** the existing weekly sound counts (weekly.yml + tiktok-extras) count every tracked
   sound; per song = videos added in 7 days summed over its sounds → invite score `tt_song_videos`. Tonight's counts
   (2026-10-22) are the baseline, so Mon 2026-10-26 already gives a gain for all 155 songs.
- Optional later: For You sampler (Vic's tool, /foryou allowed) for discovery outside the pool; spare Android phone +
  app automation (song pages, Tako); both carry TikTok-terms risk.
- Review list (offline, saved data only): `data/tiktok_trending/review_2026-10-22.csv` (`build_review_list.py`).
- (2026-10-23) SQL number: 027 is taken by the Business API (other session) → trending sounds = sql/028.
- (2026-10-23) **Creative Center with Vic's TikTok for Business login** (`login_from_pc.py --cc` → server `cc_state.json`;
  test `cc_probe2.py`, plain curl_cffi requests with the cookies; the headless browser got 403 on everything):
  PH hashtag list = **100** (logged out 3), song titles appear (#justthewayyouare, #damned) → candidate signal.
  Top videos: permission error `AGWClientTT4bAndAIOCheckError`, unchanged after creating an ad account; page config
  `videoCountry: ["US","JP","VN","TH","ID"]` → → looked closed, BUT Vic (2026-10-23): PH works when the region is picked in the page itself (the list above is likely only the fallback; the live list comes from a "trends filter config" call). **Re-test first next session.**
  Next build: logged-in hashtag list weekly (cookies expire: needs a re-login check) → match to OPM song titles.

## Built 2026-10-23 (3-part setup, sql/028)
### Step 0 result: Creative Center top videos is NOT a PH source
- Page code (`static/js/async/2424.*.js`, read 2026-10-23): filter config = `GET /cc_portal_api/api/trendsTcc` (500 for us,
  logged in or out → the page falls back to its built-in list `videoCountry: ["US","JP","VN","TH","ID"]`). Video list =
  `GET /CreativeOne/Report/CreativeCenterGetTopContentsList` (periodDimension 3 = created last 7 days, 1 = weekly;
  `periodEndTimestamp` in seconds = the weekly snapshot day, here Tue 2026-10-20 00:00 UTC; headers `Agw-Js-Conv: str` +
  `X-CSRFToken`). PH routes to ads.tiktok.com (US → ads.us.tiktok.com, EU → ads-useast2a.tiktok.com).
- `cc_probe3.py` with Vic's login, every day of the last 21: **JP, ID, VN, TH = 20 videos each; PH, MY, SG = always 0.**
  Items carry no sound id either (title, author, views only). Likely what Vic saw: when the region isn't in the list,
  the page code (`f(region, list)`) silently shows the list's first country's videos while the URL still says PH.
  Check in the browser: DevTools → Network → `CreativeCenterGetTopContentsList` → `countryCode` param, or look whether
  the videos are Filipino. Hashtags (logged in, 100 for PH) work and are used.
- Login cookies (`sessionid_ads` etc.) expire **2026-10-25**: re-login with `py login_from_pc.py --cc` before each Monday
  run until we see whether they renew on use (the weekly run logs "login expired" when only 3 hashtags come back).
### What runs
| Part | Where | What |
|---|---|---|
| Candidates | `staging.tiktok_trend_candidate` → `mart.weekly_tiktok_trending()` | kworb PH daily (OPM = 90%+ PH listeners or Vic's pool; top 50, rising 7-day or ≤14 days on chart), Viral Hits PH, new releases (Deezer, ≤28 days, and on the artist's kworb page with 1,000+ plays/day), song titles in the logged-in top 100 PH hashtags (6+ letters). 135 on 2026-10-23. kworb daily now saved by music-weekly (Mon 10:00). |
| Sounds | `raw.tiktok_trend_song` / `raw.tiktok_trend_sound` | seeded from the 2026-10-22 Sounds-tab run (`seed_trending.py`: 155 songs, 692 sounds: 285 kept, 283 dropped, 124 waiting for the caption check; 557 baseline counts dated 2026-10-22, 132 more already existed from artist_sounds). Vic's links: Google Sheet **NDN fan sounds** (`1bn1mbCuiUgdC3_5skPPi4BUf0hHo5ZGLy8qkrCNNg0w`, tab "Paste here", 30 hot songs pre-filled). Rule: credited to the artist, or 2+ captions name the artist (Vic's links: or 2+ name the song); `status_by_vic` overrides. |
| Counts | weekly.yml `artist_sounds` (Mon, now also lists tracked trend sounds) + `trending_weekly.py` counts leftovers | `staging.tiktok_sound_week` = latest count vs the count 5-14 days before, scaled to 7 days. |
| Number | `staging.tiktok_trend_song_week`, `mart.tiktok_trending_sounds` | videos added in 7 days per song over kept sounds. `mart.invite_candidates`: `tt_song_videos` (25%) ranks `new_hit_tiktok_added_7d` once any gain exists (else all-time videos, column `tt_song_basis`); the new song is picked by weekly gain first. |
| Weekly job | home server cron Mon 12:00 PH: `trending_weekly.py` | hashtags (ads.tiktok.com) → sheet links → refresh → caption votes → leftover counts → run log (`raw.music_runs` part `tiktok_trending`). Writes via Edge Function `tiktok-trending`. Claude tested hashtags + refresh only; votes/counts open tiktok.com, so Vic runs them. |
| Power BI | Who to invite page | new table "Trending OPM sounds this week" (`tiktok_trending.csv`, clickable sound link); "why" table gets "TikTok videos added in 7 days". |
- Invite view takes ~32 s (was ~24 s before 028; the materialized CTEs keep the added part small). Fix later: a
  nightly table instead of a view.
- Review list: `data/tiktok_trending/review_2026-10-23.csv` (one row per sound: status, why, link, blank "your check").
