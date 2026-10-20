# YouTube: the questions that matter

Independent analysis of public data, not affiliated with Nine Degrees North.

Draft 1, 2026-10-20. Channel @ninedegreesnorthrecords: 1.51M subscribers (YouTube rounds this), 2.19B views, 1,020 videos (about 580 long, 440 Shorts). In 2026 so far: 111 full sessions and 108 Shorts; full sessions mostly premiere Mon, Wed and Fri at 7 pm PH.
The algorithm notes behind this file live in the `social-media-management` skill (`references/youtube.md`).

## How YouTube decides who sees a video

In one sentence: for each viewer, YouTube picks the video they are most likely to click **and then watch with satisfaction**, from what they watched and searched before.

What we know, most reliable first:

1. **YouTube's own help pages (read 2026-10-20).** YouTube doesn't push videos to subscribers; it "finds videos for your audience" when they open the app. Home uses the viewer's watch history and how a video does with similar viewers. Up next uses the video being watched as the main signal. Search matches the title, description and the video itself to the query, then checks how people who searched it watched. Likes count "somewhat". Upload frequency and publish time don't change long-term views (publish time matters for Premieres). Tags barely matter.
2. **YouTube's blog (2021) and two Google research papers (2016, 2019).** Clicks alone misled, so YouTube ranks by expected watch time plus satisfaction: 1-5 star surveys ("valued watch time"), likes, shares, dislikes, "Not interested". The 2016 paper says ranking by clicks "promotes deceptive videos" (clickbait). YouTube's own title and thumbnail tests still pick the winner by watch time, not clicks.
3. **Shorts are a separate swipe feed.** Up to 3 minutes since Oct 2024. Whether Shorts watching feeds long-form recommendations is not published.
4. **Counting changed twice.** Since 31 Mar 2025 a Short's view counts every start or replay. **Since 24 Aug 2026 every view counts from the first frame**, long videos included (the old count is now "engaged views", owner only). Recommendations didn't change, but views from before and after these dates aren't like for like. Our daily snapshots started 2026-10-12, so daily gains are all on the new count.

What this means for NDN: a session earns views when viewers who click it keep watching. Search and Up next favour songs people already know and look for. And views keep coming for years: last week 69% of NDN's YouTube views came from sessions over a year old.

## What we can and cannot see

| Signal | Public (we collect it) | Only NDN can see |
|---|---|---|
| Views, likes, comment count | Yes, daily | Engaged views (old count) |
| Title, description, length, publish and premiere times | Yes, daily (raw JSON; staging uses only part) | |
| Subscribers | Channel total, rounded (1.51M) | Subscribers per video |
| Short or long | Not flagged by the API; YouTube's hidden Shorts playlist lists them | |
| Most replayed moments | Public graph, not collected yet | Retention curve, average view duration |
| Impressions, click-through rate | No | YouTube Studio |
| Where views came from (Home, Up next, Search, Shorts feed) | Search rank as a stand-in, not collected yet | YouTube Studio |
| Search terms, audience country, age, device (TV vs phone) | No | YouTube Studio |
| Shares, dislikes | No | YouTube Studio |

For watch time we use **stand-ins**, as on TikTok: the "Most replayed" graph, how fast a session collects views compared with the sessions around it, and how long it keeps collecting them. They are weaker than the real numbers, and we label them.

## The questions

Each question says why it matters, the decision it helps with, how to measure it, and whether we can answer it now.

Status words: **Now** = real data is enough. **Stand-in** = answerable with a stand-in. **Wait** = needs more days of real snapshots. **New data** = needs a new extract. **Phase 2** = needs NDN's own analytics.

★ = answer first.

Measure conventions for YouTube (same idea as TikTok Q14):
- **Performance index** = a session's views ÷ the median views of the 30 full sessions posted nearest in time (15 before, 15 after). 1.0 = typical for its period. Sessions under 14 days old are left out of lifetime comparisons.
- NDN's YouTube is far more hit-driven than its TikTok: a quarter of sessions sit under 0.2, a quarter over 8.4, the top 10% over 36. **Bands (decided 2026-10-21):** use the bands creator tools use for "outlier" videos (vidIQ: under 2×, 2-5×, 5-10×, over 10× the channel's typical video). They are a tool convention, not a YouTube rule, but the same bands work for every platform, so TikTok and YouTube can be compared. NDN YouTube sessions (551, lifetime): 2×+ 221 (40%), 5×+ 163 (30%), **hit = 10×+ 126 (23%)**. TikTok keeps "breakout = 2×" as its first band. Ours uses the median of the 30 nearest sessions, not the channel average, because one viral session would inflate an average.
- Compare Shorts with Shorts of the same period (counting changed 2025-03-31), and treat 2026-08-24 as a break for all views.

### Attract: does YouTube show new sessions beyond the fans?

**Q1 ★ Which new sessions take off, once you allow for how big the artist is?**
- Why: Home and Up next test each new video on viewers likely to enjoy it, then widen or stop. Big artists start with more people searching for them, so raw views flatter them.
- Decision: which sessions to push in their first week (Shorts, TikTok, Instagram, playlists); which artists give NDN more views than their size predicts (invite score, Q13).
- Measure: index at day 7 (views at day 7 ÷ median day-7 views of the 30 nearest sessions). Size-adjusted: actual index ÷ the index expected from the artist's Spotify monthly listeners (log-log line).
- Status: Now (lifetime version). Day-7 version: Wait. Daily snapshots began 2026-10-12 and NDN posts about 2.6 sessions a week, so about 15 sessions by early December.
- First look (real, lifetime, 551 full sessions, 2026-10-20): median index 0.93; 126 hits (index ≥ 10). Artist size matters but doesn't decide: log views vs log Spotify listeners r = 0.54 (2025: 0.65); twice the listeners goes with about 1.5× the views. Biggest over-performers for their size (2025-26): Migraine – Moonstar88 (72× expected), Bakit Ngayon Ka Lang – Freestyle (54×), Pagdating ng Panahon – Ice Seguerra (52×), Paraluman – Adie (50×), Kundiman – Silent Sanctuary (49×). All five are well-known songs (see Q5). Caveat: listeners are today's, not at upload.

**Q2 Do Shorts send viewers to the full sessions?**
- Why: Shorts run in their own swipe feed. YouTube's own creator guide (July 2026) says some Shorts-only viewers "may never naturally click on a 10-minute video", and suggests the Related video link plus a spoken ask. Shorts views have been cheap since 2025-03-31 (every replay counts).
- Decision: keep cutting Shorts from every session or move the effort to TikTok and Instagram; post them before or after the premiere; always set the Related video link.
- Measure: (a) Shorts' share of channel views. (b) For Shorts posted a day or more after their session: the session's daily views in the 3 days after vs the 3 days before, against similar sessions without a later Short. (c) Does a strong Short go with a strong session?
- Status: (a) Now. (b) Wait, and cases are rare: only 13 Shorts in 2025-26 went up 3+ days after their session. A clean answer may need a small test (NDN posts Shorts of 5 older sessions). Correct Short flag built 2026-10-20 (`staging.youtube_video_format`, from YouTube's own Shorts list): 440 Shorts, 7 of them over 60 s; length alone got 8 videos wrong.
- First look (real, 7 days to 2026-10-20): Shorts brought **1.0% of channel views** (215k of 22.1M). 191 of the 214 Shorts from 2025-26 belong to a session: 129 went up before it (median 30 minutes before the Premiere: teasers), 62 after (median the next day). Likes per 1,000 views (2026 uploads): Shorts 9.6, sessions 6.2.

### Retain: do people keep watching?

**Q3 ★ Which moment of each session do viewers replay most?**
- Why: watch time and satisfaction drive ranking. Real retention is owner-only, but YouTube shows a public "Most replayed" graph on videos with enough views: where viewers rewind and rewatch.
- Decision: which 15-30 seconds to cut for Shorts, TikTok and Instagram (the moment YouTube viewers already replay), and whether intros run too long (if peaks always come late).
- Measure: each session's 100-point "Most replayed" curve; time of the peak (skipping the first 5%, where every video starts high); how far the peak stands above the curve's median. Later: TikTok results for clips that used the peak vs other moments.
- Status: Collecting from 2026-10-20 (home server, Mondays; `staging.youtube_heatmap_peak`). New sessions get a graph once they have enough views.
- First look (2 sessions, 2026-10-20): Nang Iwan – This Band peaks at 1:46 of 6:07; Kawaii Morena – SKYGARDEN at 0:14 of 3:57.

### Engage: what makes viewers act?

**Q4 What makes viewers like and comment?**
- Why: likes and shares count as satisfaction (YouTube blog 2021), likes "somewhat" (FAQ). Comments show what fans ask for (data set 5 reads their text).
- Decision: the ask in the description or pinned comment ("Which song should they sing next?"), and which sessions deserve replies.
- Measure: likes and comments per 1,000 views vs NDN's median, by song type (Q5), series and year. Only compare within a period: the first-frame count since 2026-08-24 lowers per-view rates.
- Status: Now.
- First look (real, 2026 uploads): sessions 6.2 likes and 0.42 comments per 1,000 views; Shorts 9.6 and 0.16.

### Relevance: which songs and shows fit NDN's audience?

**Q5 ★ Does the song choice decide a session's views?**
- Why: Search ranks by how well a video matches what people type, plus how searchers watched it. Up next follows the song being watched. A well-known song has search demand and many related videos to sit next to.
- Decision: which sessions to premiere first and promote (Shorts, TikTok, Instagram), and which to cut Shorts from. Not used for song advice to artists (Vic, 2026-10-21).
- Measure: index by the song's rank among the artist's Spotify songs (kworb), within the same artist. Second cut: song age (release date from Deezer).
- Status: Now (rough answer below).
- First look (real, kworb 2026-10-20, Cozy Cove sessions): artist's #1 Spotify song: median index 13.7 (n 77, median 3.8M views); #2-5: 6.0 (125); other songs: 1.2 (102); artists too small for kworb: 0.29 (154). **Within the same artist** (53 artists with both): sessions of their top-3 Spotify songs got 9.6× the views of their other sessions; the top song won for 50 of 53 artists. Caveat: Spotify rank is today's, and a session may itself have made the song bigger (Q12 tests that direction).
- Also: 10 Cozy Cove recordings are on Spotify as audio, 23.8M streams in total (Saan? (Live at the Cozy Cove) alone 11.2M).

**Q6 Which series work: Cozy Cove, Fest, Taped Sessions, Harana?**
- Why: viewers who finish one session get the next one in Up next. A series that matches what they came for keeps them; one that doesn't is skipped.
- Decision: the content mix, and whether weaker series belong on YouTube or on other platforms.
- Measure: median index by series (groups of 10+ sessions only).
- Status: Now.
- First look (real, 2026-10-20): Live at The Cozy Cove 1.45 (n 460), The Cozy Cove Fest 3.84 (16), Harana sa Manila 0.16 (17), Taped Sessions 0.06 (39). Live at Session Road (8) and Alpas La Union (5) are too small to judge.

### Search: do people who search a song find NDN?

**Q7 ★ When someone searches a song NDN has filmed, where does the session rank?**
- Why: YouTube Search ranks by relevance (title, description, content), how searchers watched (watch time for that query) and quality. "Search results are not a list of the most-viewed videos." A session competes with the official video, lyric channels and covers.
- Decision: a title and description template (song first, artist, Spotify link; today only 42 of 1,020 descriptions link to Spotify), which songs need a fix, and which songs NDN "owns" as the top live version.
- Measure: NDN's best position in the top 25 for "<song> <artist>" (API search, region PH, not personalised), weekly; compared with the session's long-tail views (Q8).
- Status: Collecting weekly since 2026-10-20 (`staging.youtube_search_rank`, `youtube_search_result`): every Monday the 30 newest sessions + the 60 earning the most views that week.
- First look (real, 90 searches, 2026-10-20): NDN's own session is in the top 3 for 26 of the 30 newest sessions and for 33 of the 60 biggest earners (median position 2 and 3); NDN is first for 7 and 10 of them. So for searches NDN mostly shows up, but usually below the official video.

### Last: does a session keep earning?

**Q8 ★ Which old sessions keep earning views, and which come back?**
- Why: YouTube keeps recommending long videos for years through Home, Up next and Search. Its FAQ names a rising topic, binge-watching or "a new video in the series" as the reasons old videos take off.
- Decision: which songs and artists are evergreen (worth a revisit, a new Short, a playlist slot or a re-invite); which comebacks to ride with a TikTok or Instagram clip.
- Measure: views gained per day by video age; share of channel views from sessions over 1 year old; comeback = an old session's 7-day gain at least 2× its own previous 28-day median.
- Status: Now for shares (daily since 2026-10-12; YouTube counts are exact, unlike TikTok's). Comebacks: Wait about 4 weeks for the 28-day baseline.
- First look (real, 7 days to 2026-10-20): channel +22.1M views. Sessions over a year old 69%, 30 days to 1 year 29%, under 30 days 2%; Shorts 1%.

**Q9 Does a new session, or a playlist, wake up the artist's older sessions?**
- Why: Up next uses the video being watched as the main signal, so a new session puts the artist's older ones next to it. Playlists line sessions up for binge-watching.
- Decision: re-invite artists whose catalogue lifts; add each new session to a playlist on day 1; point end screens at the artist's other sessions.
- Measure: daily views of the artist's older NDN sessions in the 7 days after a new upload vs the 7 days before, minus the channel's overall change. Playlists: daily views of a video before vs after it was added (the API gives the date added).
- Status: Wait (about 3 weeks) for the artist lift. Playlists: collecting weekly since 2026-10-20 (`staging.youtube_playlist_item`, with the date each video was added).
- First look (2026-10-20): 15 public playlists: "Live at The Cozy Cove" (506 videos), "Taped Sessions" (52) and 13 mood playlists of 5-18 ("Mahabang Byahe Pauwi sa Probinsya", "Laking Computer Shop", "Backread Saglit, Relapse Ulit"). Every long video is in at least one. No description links to a playlist.

### Habits: what NDN controls

**Q10 Do Premieres and the Mon/Wed/Fri 7 pm slot matter?**
- Why: YouTube says publish time doesn't change long-term views but matters for Premieres; people who set a reminder are alerted 30 minutes before and at the start. On TikTok, "premieres TONIGHT" teasers are NDN's most shared and saved posts (TikTok Q4).
- Decision: keep Premieres and the TikTok teasers, or upload normally; which weekday gets the strongest session.
- Measure: Premiere turnout = people watching live during the Premiere (public `concurrentViewers`, only while it runs, about 6 minutes) vs the session's day-7 index; index by weekday.
- Status: weekday: Now (Mon 35, Wed 32, Fri 30 sessions in 2026). Turnout: collecting from 2026-10-21 (checks at 7:02 and 7:05 pm PH daily; `staging.youtube_premiere_turnout`), Wait for about 15 Premieres.
- First look (real): 548 of 1,020 videos were Premieres, including 110 of 111 sessions in 2026. "Premiere vs not" can't be compared; turnout is the useful number.

### Trends

**Q11 Which OPM songs and artists trend on YouTube in the Philippines, and has NDN had them?**
- Why: YouTube retired its Trending page in July 2025; the API's "most popular" list now returns the Trending Music chart per country. YouTube ads reach about 59.6M people in the Philippines (Digital 2026, secondary report), so a PH trend is a big audience.
- Decision: invite candidates with momentum (invite score "Momentum"); songs to schedule while they are hot.
- Measure: daily snapshot of the 30 PH Trending Music videos; artists matched to NDN's and the Spotify artist list; days on the list per artist.
- Status: Collecting daily since 2026-10-20 (`staging.youtube_trending_ph`). Matching artists from titles: later, with dashboard v3 (Vic, 2026-10-21).
- First look (2026-10-20): 30 videos, none from NDN; led by lyric channels and VEVO uploads, so artists must be read from video titles.

### Music outcome: why a label is on YouTube

**Q12 ★ Flagship: does a Cozy Cove session lift the artist's Spotify streams?**
- Why: the end goal is listeners. Up next and Search put the song in front of new viewers, some of whom then stream it.
- Decision: which artists and songs to schedule; whether to release the live audio on Spotify (10 already are); what to tell artists ("a session added about X streams a week").
- Measure: for each new session, the performed song's weekly Spotify streams (difference in kworb totals week to week), 4 weeks before vs 4 weeks after the Premiere, compared with the same artist's other songs over the same weeks. The other songs absorb the artist's general trend, a new release or a concert (difference-in-differences). Also: change in monthly listeners; for artists too small for kworb, the song's play count in their Spotify top 10. Check: does a bigger YouTube response (day-7 index, Q1) bring a bigger lift?
- Status: Wait. Weekly Spotify and kworb history starts 2026-10-20 (data set 3). With 4 weeks before and after, the first usable sessions are those premiered from about 2026-11-16, read from mid-December; a solid answer needs about 15 sessions, so about January 2027. Needs one SQL step, no new extract: a link from each session to its Spotify track (studio and live versions).
- First look: none yet (no history). 121 of 279 artists have kworb pages; the rest only have monthly listeners and top-10 play counts.

**Q13 How do YouTube results feed the invite score?**
- Why: the score (`INVITE_SCORE.md`) gives 15% to "NDN track record" and 15% to "Fan demand"; both need YouTube.
- Decision: who to invite next (no song advice: Vic, 2026-10-21).
- Measure:
  - Track record, YouTube half: median index of the artist's sessions at least 30 days old (Q1), plus the size-adjusted ratio (Q1) and their share of NDN's current daily views (Q8). Once Q12 has answers: the Spotify lift. New artists get 50 and a "new" tag.
  - Fan demand: YouTube comments naming the artist (data set 5).
  - Cooldown (10 months) starts from the first YouTube upload of the latest visit, as now.
- Status: Now for the index; size-adjusted and evergreen parts Now; lift Wait; fan demand after data set 5.
- First look (real, Cozy Cove sessions 2024-26, artists with 3+ sessions, median index): Dionela 105, Silent Sanctuary 95, Moonstar88 76 (latest visit Jan 2026, so cooling down until about Nov 2026), Freestyle 63, Sponge Cola 47, fitterkarma 46.

**Q14 What should NDN post on YouTube next week?**
- Why: the point of the list: turn answers into a short brief.
- Decision: the week's plan: which sessions to premiere on which day, which Short to cut and when, title and description, playlist slots, which old sessions to revive.
- Measure: built from Q1, Q3, Q5, Q7, Q8 and Q10; written by the daily Claude routine once those are answered.
- Status: Wait (needs the ★ answers first).

### Phase 2: only with NDN's YouTube Studio

- Impressions and click-through rate, by traffic source (Home, Up next, Search, Shorts feed, playlists, end screens).
- Average view duration, % viewed, the retention curve and key moments; for Shorts, "stayed to watch vs swiped away".
- Search terms that found NDN; which videos sent viewers to which (Up next pairs).
- Subscribers gained per video; new vs returning viewers; audience country, city, age and device (TV vs phone).
- End screen and Related video clicks; Premiere peak viewers; engaged views.
- Content ID: other people's uploads and Shorts using NDN recordings.

This list is also the ask when Vic offers NDN free analyst work.

## What comes next

1. Vic reviews this list: cut, add or reorder questions.
2. Answer with data we already have: Q1 first (it fixes the index and the "hit" line every other question uses), then Q5, Q8, Q6, Q4.
3. Add the extracts the other questions need (gap list below; build only after Vic agrees).
4. Then redesign the YouTube page of dashboard v3 so each chart answers one ★ question (with the `dataviz` skill).

## Data (built 2026-10-20, Vic agreed "build all")

Already collected daily (Edge Function `youtube-snapshot`, 09:00 PH, about 43 API units of 10,000): every video's stats, title, description, length, publish and Premiere times, captions flag, plus channel totals. Weekly Spotify, kworb and Deezer come from data sets 1 and 3.

Built (`sql/016_youtube_extras.sql`, Edge Function `youtube-extras`, `extract_youtube_heatmap.py`):

| When (PH) | What | Where it lands |
|---|---|---|
| Mon 10:20 | "Most replayed" graphs (home server cron, `~/ndn_youtube`, yt-dlp from the ndn_tiktok venv) | `raw.youtube_heatmap` → `staging.youtube_heatmap_peak` |
| Mon 11:00 | Shorts list, playlists + items, 90 searches (pg_cron `ndn-youtube-extras-weekly`) | `raw.youtube_extras` → `staging.youtube_video_format`, `youtube_playlist(_item)`, `youtube_search_rank`, `youtube_search_result` |
| Daily 09:10 | PH Trending Music list (pg_cron `ndn-youtube-chart-daily`) | `staging.youtube_trending_ph` |
| Daily 19:02, 19:05 | Premiere live viewers (pg_cron `ndn-youtube-premiere-check`; saves only when a Premiere is live) | `staging.youtube_premiere_turnout` |
| SQL only | Description, captions, Premiere times; session → Spotify track (studio, Cozy Cove audio, top 10) | `staging.youtube_video_details`, `staging.youtube_session_spotify` |

Runs are logged in `raw.music_runs` (part `youtube_weekly`, `youtube_chart`, `youtube_premiere`, `youtube_heatmap`). Re-run a part by hand: POST `youtube-extras?part=weekly&force=1` with the x-cron-secret header. Cost: about 36 units on Mondays + 5 a day; 90 of the 100 daily searches on Mondays. The Shorts list uses an undocumented playlist (`UUSH…`); if it ever fails, the view falls back to length. Session → Spotify matched 1,053 of 1,208 video-artist pairs (742 on kworb, 311 in the top 10 only).

The original gap list:

| Gap | Questions | Extract that fills it |
|---|---|---|
| True Short flag | Q2, all Shorts splits | Data API: YouTube's hidden Shorts playlist, weekly (about 10 units) |
| Playlists and the date each video was added | Q9 | Data API, weekly (about 20 units) |
| Search rank of each session | Q7 | Data API search bucket: about 90 searches every Monday (100 a day free) |
| PH Trending Music list | Q11, invite Momentum | Data API, daily (1 unit) |
| Premiere turnout | Q10 | Data API at 7:02 and 7:05 pm PH (about 4 units a day) |
| Most replayed graph | Q3 | yt-dlp on the home server, weekly (all 580 long videos once, then new ones) |
| Session → Spotify track link | Q5, Q12, Q13 | SQL view only (kworb and Spotify top tracks already collected) |
| Description, captions, Premiere times as columns | Q7, Q10 | SQL view only (already in raw) |
| YouTube comments | Q4, Q13 fan demand | Data set 5 |
| Click-through rate, watch time, traffic sources, subscribers per video | Phase 2 list | Not public |

## Exercises (about 10 minutes each)

1. In the Supabase SQL editor, list each video's views gained over the last 7 days (latest snapshot minus the one 7 days earlier) from `staging.youtube_video_snapshot`, top 10. Finished = 10 rows. How many are over a year old?
2. Before Q7 runs, guess: for how many of NDN's 20 newest sessions will NDN be in the top 3 when you search "<song> <artist>"? Write the number down; we will check it.
3. On a computer, open "Nang Iwan (Live at The Cozy Cove) - This Band" on YouTube and hover over the progress bar. Find the "Most replayed" peak (about 1:46). Then find NDN's TikTok clip of the same song: does it use that moment?

## Sources

Full list with dates in the skill file `references/youtube.md`. Main ones:

- How YouTube recommendations work (Help): https://support.google.com/youtube/answer/16089387
- Discovery and performance FAQs (Help): https://support.google.com/youtube/answer/141805
- How YouTube search works (Help): https://support.google.com/youtube/answer/16090438
- A/B test titles & thumbnails (Help): https://support.google.com/youtube/answer/16391400
- Goodrow, "On YouTube's recommendation system" (YouTube Blog, Sept 2021): https://blog.youtube/inside-youtube/on-youtubes-recommendation-system/
- Engaged views and the first-frame view count (YouTube Blog, Aug 2026): https://blog.youtube/inside-youtube/engaged-views-youtube-explained/
- Shorts to long-form guide (YouTube Blog, July 2026): https://blog.youtube/creator-and-artist-stories/youtube-related-videos-traffic-guide/
- YouTube Data API revision history: https://developers.google.com/youtube/v3/revision_history
- Covington et al. 2016 (Google): https://research.google/pubs/pub45530/ and Zhao et al. 2019 (Google): https://research.google/pubs/recommending-what-video-to-watch-next-a-multitask-ranking-system/
