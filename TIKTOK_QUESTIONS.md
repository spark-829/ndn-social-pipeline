# TikTok: the questions that matter

Independent analysis of public data, not affiliated with Nine Degrees North.

Draft 1, 2026-10-18. Account @ninedegreesnorth: 324,955 followers, 979 videos, about 13 posts a week, median length 30 s.
The algorithm notes behind this file live in the `social-media-management` skill (`references/tiktok.md`).

## How TikTok decides who sees a video

In one sentence: for each viewer, TikTok predicts how long they will watch and whether they will like, comment or share, then shows the videos with the best predicted score.

What we know, most reliable first:

1. **TikTok's own explanation (June 2020).** It ranks on what viewers do (likes, shares, follows, comments), on the video's details (caption, sound, hashtags) and, with less weight, on language, country and device. Watching a longer video to the end is a strong signal. Follower count and past hits are **not** direct factors. The feed avoids two videos in a row with the same sound or creator.
2. **Leaked internal guide "TikTok Algo 101" (New York Times, Dec 2021; TikTok confirmed it was real).** Simplified score = chance of a like × its value + chance of a comment × its value + expected watch time × its value + chance of a play × its value. The goal is that people come back and spend time. It mixes in variety because "repetitiveness leads to boredom".
3. **How creators describe it (not confirmed by TikTok).** A new video goes to a small test group. If they watch and react better than for similar videos, it goes to a bigger group, and so on.
4. **2026.** In the US the algorithm is being retrained on US data under the new US joint venture. The Philippines uses the global version. Blog rules such as "shares count 10× likes" or "aim for 70% completion" are guesses; we test them on NDN's data instead.

What this means for NDN: every video earns its own audience. Watch time is the main currency. Shares, saves, comments and likes are the signals we can see.

## What we can and cannot see

| Signal | Public (we collect it) | Only NDN can see |
|---|---|---|
| Views, likes, comments, shares, saves | Yes, daily | |
| Length, caption, post time, sound | Yes | |
| Followers | Account total, daily | Follows per video |
| Watch time, % who finish, drop-off | No | TikTok Studio |
| Where views came from (For You, Search, Following) | No | TikTok Studio |
| Audience country, age, new vs returning | No | TikTok Studio |
| Other people's videos using an NDN song | Public on the sound page, not collected yet | TikTok for Artists |

For watch time we use **stand-ins**: numbers we can see that move with the one we can't. Examples: how fast views grow in the first days, and how far a video gets past the follower count. TikTok only keeps widening the audience when people watch, so these follow watch time. They are weaker than the real thing, and we label them.

## The questions

Each question says why it matters, the decision it helps with, how to measure it, and whether we can answer it now.

Status words: **Now** = real data is enough. **Stand-in** = answerable with a stand-in. **Wait** = needs more days of real snapshots. **New data** = needs a new extract. **Phase 2** = needs NDN's own analytics.

★ = answer first.

### Attract: is TikTok showing our videos to new people?

**Q1 ★ How often does a video break out, and is that getting more or less frequent?**
- Why: there is no follower boost. A video that reaches far past the follower count was pushed by the For You feed.
- Decision: study the breakouts and make more like them; spot a slump early.
- Measure: breakout = views at day 7 at least 2× the median of NDN's previous 30 videos at day 7. Rough version for now: lifetime views ÷ followers.
- Status: Now (rough version). Day-7 version: Wait, about 5 weeks.
- First look (real, 2026-10-18): 90 of 979 videos (9%) have more views than NDN's current follower count; in the last 30 days, 6 of 57. Older videos were posted when NDN had fewer followers, so this undercounts old breakouts.

**Q2 How fast does a new video take off, and does day 1 predict the final result?**
- Why: if the test-group model is right, the first hours and days decide how far a video goes.
- Decision: an early warning. A slow start can be retried with a different first 2 seconds or a different moment of the same song.
- Measure: views at the 1st, 2nd and 3rd daily snapshot; share of 14-day views reached by day 2.
- Status: Wait. Only 9 videos were posted since real tracking began (2026-10-13). The synthetic backfill can't answer this: we made those curves ourselves.

### Retain: do people keep watching?

**Q3 ★ Which video length works best for NDN?**
- Why: watch time is the strongest signal. Short clips are easier to finish; longer ones earn more watch time if they hold attention.
- Decision: a target length for each type of clip.
- Measure: median views, and saves per 1,000 views, by length group (under 15 s, 15-30 s, 30-60 s, over 60 s), comparing videos of similar age.
- Status: Stand-in (we see results, not watch time). The real answer (average watch time, % who finish, where people drop off) is Phase 2.

### Engage: what makes viewers act?

**Q4 ★ Which videos get shared and saved the most per 1,000 views, and what do they have in common?**
- Why: a share sends the video straight to new people. A save means "I'll watch this again", which adds watch time. Likes are the cheapest signal.
- Decision: find the shareable moment (a lyric line, a high note, a duet) and put it first.
- Measure: shares, saves, comments and likes per 1,000 views, compared with NDN's median.
- Status: Answered 2026-10-19 (real, snapshot 2026-10-19, 980 videos; groups use videos with 1,000+ views).
- First look (real, median per 1,000 views, all videos): 36.7 likes, 2.61 saves, 1.89 shares, 0.29 comments.
- Answer: shares + saves per 1,000 views go together with reach. Split into 4 equal groups: lowest (under 2.1) median performance index 0.48, 2% reach 2x; highest (8.7+) median index 7.45, 78% reach 2x. This is a link, not proof of cause, but it matches the algorithm (shares and saves score higher than likes).
- By caption type (median shares / saves per 1,000): premiere teaser "premieres TONIGHT" 3.31 / 4.09 (n 156); out-now/stream 2.24 / 3.48 (237); song clip with title 1.89 / 2.73 (215); other (talk, relatable line, misc) 1.35 / 1.95 (286); event/tickets 1.07 / 0.92 (86).
- By length: 15-30 s best (2.16 / 3.04, n 521); under 15 s worst (0.85 / 1.76).
- Shares vs saves are different jobs (correlation 0.49): saves = slow, emotional song moments (Tingin Reimagined 15.8 saves, What if I miss you 15.6, Paksa 14.6); shares = "send this to someone" posts: Buko 123.8 shares (record), Happy October 40.6, relatable-line captions ("nawalan ka na nga ng jowa..." 24.5), date/line-up reveals (shared but rarely saved).
- Weakest: 2025 "out now on YouTube" uploads over 55 s and talk segments (0-0.4 shares per 1,000).
- Decision: lead with a 15-30 s song moment; for saves pick the emotional peak, for shares pair it with a relatable line caption or a "tag someone" hook; keep event posts short and ask for a tag.

**Q5 Why are comments so low, and which posts start conversations?**
- Why: comments are one of the four actions in the leaked scoring formula. NDN gets about 1 comment per 3,400 views, its weakest visible signal.
- Decision: test captions that ask something ("Which line hits you?") and replying to comments.
- Measure: comments per 1,000 views, captions with a question vs without.
- Status: Now.

### Relevance: what fits NDN's audience?

**Q6 ★ Which types of clip, songs and artists beat NDN's own average?**
- Why: TikTok matches videos to interests through captions, sounds and hashtags. Knowing what NDN's viewers respond to tells you what to post more of.
- Decision: the content mix (for example: how many session clips vs behind-the-scenes vs event posts).
- Measure: median views ÷ NDN's median for the same period, by clip type, song, artist and series.
- Status: Now, after one new step: tag each video's clip type (Claude suggests a tag from the caption, Vic checks a sample of 30).

**Q7 ★ Original sound or the official track?**
- Why: the sound is one of the video details TikTok reads, and each sound has a page that collects every video using it. The official track ties those videos to the song.
- Decision: which audio to upload with each clip.
- Measure: median views and shares per 1,000 views, original sound vs named track, same period.
- Status: Now.
- First look (real, lifetime, not yet adjusted for age or clip type): 902 original-sound videos, median 13,950 views; 77 named-track videos, median 4,726.

**Q8 Do captions that name the song or artist keep earning views for longer?**
- Why: people search TikTok for songs, and search reads captions.
- Decision: a caption template (hook line + song + artist + session).
- Measure: share of views that arrive after day 7, captions with vs without the song or artist name.
- Status: Wait, about 6 weeks.

### Grow: do viewers become fans?

**Q9 ★ Which videos bring followers, not just views?**
- Why: TikTok doesn't rank by follower count, but followers are NDN's fans. They see posts in the Following feed and come to lives and shows.
- Decision: which formats to turn into a series.
- Measure: followers gained in the 1-2 days after a post ÷ views that video gained in those days. NDN posts about twice a day, so split each day's follower gain by each video's share of that day's views.
- Status: Wait for a solid answer (about 4 weeks); a rough version works now.
- First look (real): 319,630 followers on 2026-10-13 → 324,955 on 2026-10-18, +5,325 in 5 days after a small dip on 10-14 (−435).

### Last: does a video keep working?

**Q10 How long do videos keep earning views, and which old ones come back?**
- Why: old videos return through search, other people using the sound, or trends. A comeback shows what is evergreen.
- Decision: repost or remake songs that come back; promote them on YouTube and Instagram.
- Measure: days to reach 90% of 30-day views; old videos (over 30 days) with a sudden jump in daily views.
- Status: Now for comebacks (daily gains since 2026-10-13). TikTok rounds counts above 10,000 to 3 digits, so daily gains on big videos are rough. 30-day life curves: Wait.

### Habits: what NDN controls

**Q11 Do post time, weekday and posts per day change the results?**
- Why: two NDN posts close together compete for the same viewers, because the feed avoids showing the same creator twice in a row. Timing decides who is scrolling when the test group is picked.
- Decision: the posting schedule.
- Measure: median views by time window (PH time: morning, afternoon, evening, late night), by weekday, and by number of posts that day.
- Status: Now, with care: compare videos of similar age, and only groups of at least 10 videos.

### Music outcome: why a label is on TikTok

**Q12 ★ Are other people making videos with NDN songs, and is that growing?**
- Why: for music, other people's videos with your sound are the discovery engine. TikTok for Artists tracks exactly this per song.
- Decision: which songs to push, and which clip to use as the sound.
- Measure: number of videos on each NDN sound page, daily; new videos per week.
- Status: New data. Sound pages are public; test whether the extractor can read the count.

**Q13 Does a TikTok spike come before a Spotify or YouTube spike for the same song?**
- Why: the end goal is listeners. This links TikTok to the flagship Spotify question.
- Measure: daily TikTok views gained per song vs Spotify daily streams (kworb) and YouTube views gained, 0-7 days later.
- Status: Wait for Step 4 (kworb) and 6-8 weeks of real data.

### Added by Vic (draft 2, 2026-10-18)

**Q14 ★ Is a 10k-view video today worth the same as a 10k-view video in 2023?**
- Why: TikTok in the Philippines grew fast (ad reach of adults: about 36M in early 2022, 43M in 2023, 62M in Jan 2025, per DataReportal), NDN's followers grew, and the algorithm changed. Raw views from different years aren't comparable.
- Decision: which videos were really strong for their time, so old winners aren't overrated and new ones underrated.
- Measure (main): performance index = video views ÷ median views of NDN's 30 videos posted nearest in time (1.0 = typical for its period). This absorbs platform growth, follower growth and algorithm changes at once. Check: views ÷ PH TikTok users in the posting year.
- Status: **Answered (method chosen), 2026-10-18.** Index = views ÷ median views of the 30 neighbouring posts (15 before, 15 after, the video itself excluded). Show it on a log scale (×2 and ÷2 look equally far from 1). Breakout = index ≥ 2. Videos under 14 days old are left out until they have had time to collect views.
- Why this and not PH users: median views per post fell from about 24-26k (2023-24) to 9-12k (2025-26), while PH TikTok users grew from 43M to 62M. Users can't explain a fall. Posts per year went 79 → 106 → 392 → 401, so each post now shares the audience with about 4× as many NDN posts. Total views still rose every year: 8.4M (2023), 21.7M (2024), 44.6M (2025), 59.6M (2026 so far). Dividing by users would make recent posts look even weaker; the neighbour median corrects for users, followers, posting volume and algorithm changes at once. After the index, every year sits at a median of about 1.0 (2023: 1.04, 2024: 1.05, 2025: 0.95, 2026: 0.98).
- Caveat: a 2023 video kept collecting views after 2023, so dividing it by 2023 users alone would be wrong; the neighbour median avoids that.

**Q15 ★ Do hashtags help NDN videos, and which ones?**
- Why: TikTok officially reads hashtags as video details that tell it who to test a video on. No independent study measures their effect; a vendor study (Metricool 2026) reports about 5% more views with hashtags. Treat them as labels, not a growth hack.
- Decision: a hashtag set per clip type (for example #opm #cozycove #baguio + song + artist).
- Measure: performance index (Q14) by number of hashtags and by tag.
- Status: New data. Our captions are cut off in the profile list (tags show up as `#cozyc`, `#liveatthec`), so tags must come from each video's own page.
- First look (real, cut-off captions, not adjusted): no tags 741 videos, median 9,821 views; 1-3 tags 223 videos, median 25,100; 4+ tags 15 videos, median 11,900. Top tags: #cozycove, #liveatthecozycove, #opm, #baguio.

> 2026-10-20: weekly "TikTok extras" now collect, per video: sound (id, original or not), TikTok's real repost count, tagged place, @mentions, TikTok's suggested search words; per sound: how many videos use it (Q12, `staging.tiktok_sound_stats`); all top-level comments (`staging.tiktok_comment`); artists' own TikTok accounts and benchmark accounts (`staging.tiktok_account_snapshot_other`). Details in `TikTok_NDN.md`.

**Q16 Does joining a trend (trending sound or hashtag in the PH) lift a video, and how often do NDN songs become trends?**
- Why: blogs say trending audio boosts reach, but no solid study shows it; one academic study (660 travel videos) found cover sounds had no effect on views. For a label the bigger question is the reverse: do NDN's songs become the trend.
- Decision: whether to spend effort on trend posts, and which songs to push when they start trending.
- Measure: performance index of trend posts vs NDN's normal posts; days each NDN song appears in TikTok Creative Center's PH top songs.
- Status: Data collecting weekly since 2026-10-19 (`TikTok_NDN.md`, "Built 2026-10-19"). TikTok removed Creative Center's songs list, so the measure changes: trending songs = **weeks each NDN artist's song spends in Spotify PH's weekly top 200** (kworb, `staging.trend_spotify_ph_ndn`); trending hashtags = Creative Center's PH top 3 overall + per industry (`staging.trend_tiktok_hashtag`, 60 a week). History builds from now (no back-data), so trend-vs-normal post comparisons need a few months.

**Q17 What should NDN post next week?**
- Why: this is the point of the whole list: turn answers into a short posting brief.
- Decision: the week's plan: which songs, which moments, length, sound, caption and tags, timing.
- Measure: built from Q1, Q3, Q4, Q6, Q7, Q11, Q14-Q16; written by the daily Claude routine once those are answered.
- Status: Wait (needs the ★ answers first).

### Phase 2: only with NDN's TikTok Studio

- Average watch time and % who watch to the end, per video.
- Where viewers drop off (the first 3 seconds?).
- Where views come from: For You, Following, Search, Sound, profile.
- The search terms that found NDN videos.
- Audience country and age; new vs returning viewers.

This list is also the ask when Vic offers NDN free analyst work.

## What comes next

1. Vic reviews this list: cut, add or reorder questions.
2. Answer the ★ questions that real data supports now: Q14 first (every other comparison uses its index), then Q4, Q7, Q1, Q6, Q3.
3. Add the data steps they need:
   - Per-video details (new script, run once for all 979 videos, then only new ones daily): full caption, hashtags, and TikTok's own captions file where it exists. Tested 2026-10-18 with yt-dlp: a recent video has Filipino auto-captions (`fil-PH`), a 2022 video has none.
   - Transcripts for videos without captions: free local speech-to-text (Whisper) is possible, but sung lyrics transcribe poorly. Songs are better identified from the sound name, the caption and the title parser; transcripts mainly help sort clip types (talking, announcement, performance).
   - Clip-type tag per video: Claude suggests one from caption + transcript, Vic checks a sample of 30.
   - Weekly TikTok Creative Center snapshot of PH trending songs and hashtags (Q16), and sound page counts (Q12).
4. Redesign the TikTok dashboard page so each chart answers one ★ question (with the `dataviz` skill).

## Exercises (about 10 minutes each)

1. In the Supabase SQL editor, write a query that lists shares per 1,000 views for each video in `staging.tiktok_video_snapshot`, latest day only, highest first. Finished = 979 rows. Open the top 3 on TikTok: what do they have in common?
2. Before we run Q7 properly, guess whether original sound still wins when you compare only videos from the last 6 months. Write the guess down; we will check it.
3. Pick one question and write the decision NDN would make if the answer were "yes", and if it were "no". If both answers lead to the same decision, the question doesn't deserve a chart.

## Sources

- TikTok Newsroom, "How TikTok recommends videos #ForYou" (18 June 2020): https://newsroom.tiktok.com/en-us/how-tiktok-recommends-videos-for-you/
- New York Times, "How TikTok Reads Your Mind" (Dec 2021), reprinted by Boston.com: https://www.boston.com/news/commentary/2021/12/06/how-tiktok-reads-your-mind
- ABC7, US joint venture and the retrained algorithm: https://abc7news.com/post/oracle-will-manage-tiktoks-algorithm-us-users-trump-administration-deal/17866333/
- TikTok for Artists (Influencer Marketing Hub): https://influencermarketinghub.com/tiktok-for-artists-rolls-out-globally/
- DataReportal, TikTok in the Philippines: https://datareportal.com/reports/digital-2022-philippines and https://datareportal.com/essential-tiktok-stats
- Metricool TikTok study 2026 (vendor, hashtags): https://metricool.com/tiktok-trends/
- Cover sound study, 660 travel videos (University of Jyväskylä): https://jyx.jyu.fi/handle/123456789/85172
- TikTok Creative Center guide (Collabstr): https://collabstr.com/blog/tiktok-creative-center
- 2026 blog round-ups, used only as ideas to test: https://blog.hootsuite.com/tiktok-algorithm/ and https://www.socialpilot.co/blog/tiktok-algorithm
