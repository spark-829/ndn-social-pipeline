# Instagram: the questions that matter

Independent analysis of public data, not affiliated with Nine Degrees North.

Draft 1, 2026-10-21. Account @ninedegreesnorthrecords: 120,173 followers (exact, about +250 a day this week), 874 posts on the profile (the API returns 898). In 2026 so far: 157 Reels, 43 carousels and 27 photos, about 5.4 posts a week. Most Reels point to a YouTube session: "premieres TONIGHT at 7PM" posted at 6 pm, then "now streaming" after.
Reel views below come from a one-off, read-only pull on 2026-10-21 (all 898 posts, 10 API calls). The daily pull doesn't collect views yet (see Data).
The algorithm notes behind this file live in the `social-media-management` skill (`references/instagram.md`).

## How Instagram decides who sees a post

In one sentence: each part of Instagram (Feed, Reels, Explore, Stories, Search) ranks posts separately, predicting for each viewer whether they will keep watching, like, share and follow; Instagram says the three signals that matter most are **watch time, likes and sends** (shares by DM).

What we know, most reliable first:

1. **Meta's own "system cards" (read 2026-10-21; Reels card updated Nov 2025, Explore, Feed recommendations and Search June 2026).** For every viewer, the Reels feed predicts: will they watch **less than 3 seconds**, watch **more than 95% of people who watched reels of the same length**, comment, reshare, share outside Instagram, follow the account, use the reel's audio, tap "Interested". Explore adds spending over 5 seconds, saving and "Not interested". Search ranks account names, keywords and hashtags by how well they match the words typed and how often people in the same country click them; captions aren't named.
2. **Adam Mosseri, head of Instagram.** "Instagram Ranking Explained" (May 2023): there is no single algorithm; Reels look at your activity, your history with the account, the reel itself (audio, visuals, popularity) and the account. Reels that are low-resolution, watermarked, muted, framed with borders, mostly text or reposted from others are shown less. Video of January 2025: "The top three signals that matter most for ranking are watch time, likes and sends." Likes count slightly more with followers, sends slightly more with non-followers.
3. **Originality (Instagram creators blog, 30 Apr 2026).** Accounts that mostly repost other people's photos, carousels or reels lose recommendations. NDN films its own sessions, so this works for NDN: pages that re-upload NDN clips should lose reach to the originals.
4. **Counting and features changed.** "Views" count every start and replay (since Aug 2024). Reels can run 3 minutes (Jan 2025). The Repost button (Aug 2025) shows a reposted reel to the reposter's followers, and the count is public. Since April 2026 a Reel's public view count includes its Facebook views if it was shared to Facebook. Hashtags were capped at 5 per post (reported Dec 2025; Mosseri: hashtags are "not a way to get more reach"), yet 39 NDN posts since then carry 6-9. "Your Algorithm" (Dec 2025, all of Instagram since June 2026) lets viewers see and edit the topics behind what they're shown.

What this means for NDN: a Reel earns reach when the people it's tested on watch it, like it and pass it on. Followers see posts in Feed; the big numbers come from non-followers in Reels and Explore, where sends weigh more. And Instagram has almost no long tail: last week 44% of NDN's new likes went to posts under a month old and 1% to posts over a year old (YouTube: 69% of views come from sessions over a year old). In the Philippines Instagram reaches 26.9M people (ad reach, late 2025), far fewer than TikTok (64.0M adults) but growing fastest: +24.6% in a year (DataReportal 2026).

## What we can and cannot see

| Signal | Public (we collect it) | Only NDN can see |
|---|---|---|
| Likes, comment count | Yes, daily (likes hidden on 26 posts) | |
| Reel views | Public in the API, **not collected daily yet** | Reach (unique accounts); views from followers vs non-followers |
| Reposts | Public in the API since Apr 2026, **not collected daily yet** | Sends (DM shares), shares outside Instagram, saves |
| Caption, type (Reel, carousel, photo), post time | Yes, daily | |
| Followers | Account total, exact, daily | Follows per post, profile visits |
| Watch time | No | Average watch time, skips under 3 s, retention graph |
| Where views came from (Feed, Reels tab, Explore, Stories, Search, profile) | No | Insights |
| Stories | No (the API doesn't return another account's Stories) | Views, replies, link clicks |
| Comment text | No (the API refuses; tested 2026-10-21) | Yes |
| Reels made with NDN's audio | No (audio pages need a login) | Partly |
| Collaborators on a post | No (the API refuses) | Yes |
| Facebook part of a Reel's views | No (the public count includes it since Apr 2026) | Insights (`facebook_views`) |
| Audience country, city, age | No | Insights |

Watch time, sends and reach are hidden, so we use **stand-ins**: views compared with the Reels around it (performance index), likes and reposts per 1,000 views, and views ÷ followers as a rough "reach beyond followers". They are weaker than the real numbers, and we label them.

## The questions

Each question says why it matters, the decision it helps with, how to measure it, and whether we can answer it now.

Status words: **Now** = real data is enough. **Stand-in** = answerable with a stand-in. **Wait** = needs more days of real snapshots. **New data** = needs a new extract. **Phase 2** = needs NDN's own Insights.

★ = answer first.

Measure conventions for Instagram:
- **Performance index** = a Reel's views ÷ the median views of the 30 Reels posted nearest in time (15 before, 15 after). 1.0 = typical for its period. Reels under 14 days old are left out of lifetime comparisons.
- Same bands as YouTube and TikTok: 2×, 5×, 10×. NDN's Instagram is less hit-driven than its YouTube: of 622 Reels, 26% reach 2×, 12% 5× and 6% (39) 10× (YouTube sessions: 40%, 30%, 23%).
- Photos and carousels have no public view count. Compare them on likes, comments and reposts per post, never with a Reel's per-view rates.
- Public Reel views count replays, include paid views if a Reel was boosted, and since April 2026 include Facebook views of Reels shared to Facebook. Compare Reels with Reels of the same period: the median Reel got 9k views in 2023, 22k in 2024, 36k in 2025 and 45k in 2026.
- Reposts exist since 6 Aug 2025; compare them only for Reels posted after that date.

### Attract: does Instagram show NDN's Reels beyond its followers?

**Q1 ★ Which Reels break out, once you allow for how big the artist is?**
- Why: Reels and Explore show posts mostly to non-followers and widen the audience when the people they're tested on watch, like and send (Mosseri 2023 and 2025; Reels system card). A big artist brings fans who would watch anyway.
- Decision: which Reels to push further in their first days (Stories, a second cut, a collab post with the artist); which artists get NDN more reach on Instagram than their size predicts (invite score, Q13).
- Measure: index at day 7 (views at day 7 ÷ median day-7 views of the 30 nearest Reels); lifetime index until then. Size-adjusted: actual index ÷ the index expected from the artist's Spotify monthly listeners (log-log line), as in YouTube Q1. Rough reach beyond followers: views ÷ followers on the day.
- Status: Now (lifetime, from the one-off pull). Day-7 version: New data (add views to the daily pull), then Wait: NDN posts about 3.8 Reels a week, so about 15 Reels by late November.
- First look (real, 2026-10-21, 622 Reels at least 14 days old): median 28k views, 2026 median 45k. 24% of 2026 Reels got more views than NDN has followers (13% of all Reels). Artist size matters less than on YouTube: log views vs log Spotify listeners r = 0.50 (2025-26); twice the listeners goes with 1.23× the views (YouTube 1.5×). Biggest over-performers for their size (2025-26): What if I miss you for the rest of my life? – Janine Berdin (11.1M views, 68× expected), Hangin – Yno (23×), Kay Tagal Kitang Hinintay – Karylle & The Passport Holders (22×), Sana Tumawag – Sica, Uncle Dags (19×), Mahal Magmahal – Esremborak (15×).

**Q2 What does each format do: Reels, carousels, photos?**
- Why: only Reels compete in the Reels tab; photos and carousels mostly reach followers in Feed, where likes count more (Mosseri 2025). Sharing is what carries a post to non-followers.
- Decision: the mix (2026: 157 Reels, 43 carousels, 27 photos) and what each format is for: Reels for reach, carousels for news and photo sets for fans.
- Measure: median likes, comments and reposts per post by format, same months.
- Status: Now.
- First look (real, 2025-26 posts): Reels 1,021 likes, 7 comments, 140 reposts per post; carousels 1,018 likes, 3 comments, 55 reposts; photos 546 likes, 4 comments, 69 reposts. Carousels please fans as much as Reels do, but Reels get passed on more than twice as often.

### Retain: do people keep watching?

**Q3 Which opening moment and length keep viewers watching?**
- Why: watch time is first of Mosseri's top three. The Reels card predicts a skip in under 3 seconds and watching longer than most viewers of reels the same length. All of it is owner-only.
- Decision: open every Reel on the strongest moment (for example the YouTube "Most replayed" peak, YouTube Q3) and choose a length.
- Measure: Phase 2: average watch time, skip rate and retention per Reel. Before that: tag 20-30 Reels by whether they open on the YouTube peak and compare their index; or, once NDN takes part, two cuts of one song as Trial Reels (shown to non-followers first, results after about 24 hours).
- Status: Phase 2. The stand-in needs manual tagging. Reel length isn't in the public API.
- First look: none.

### Engage: what makes viewers act?

**Q4 ★ Which Reels get passed on, and does passing on bring reach?**
- Why: sends are one of the top three signals and matter most for reaching non-followers (Mosseri 2025). Sends are owner-only, but reposts are public: a reposted Reel is shown to the reposter's followers (Instagram, Aug 2025).
- Decision: which songs, artists and moments to make more of; which artists' fans pass NDN's posts on (invite score "Fan demand", Q13).
- Measure: reposts per 1,000 views (Reels since 6 Aug 2025) next to likes per 1,000 views, compared with the index; what the most-shared Reels have in common (song, artist, caption type).
- Status: Now (one-off pull). Daily: New data.
- First look (real, 228 Reels posted since 2025-08-06): median 3.8 reposts per 1,000 views in 2026 (2025: 2.8). Reposts go with reach: r = 0.53 with the index (likes: also 0.53). Five Reels hold 43% of the 236,880 reposts. Most passed on per view: Baka Bukas – Angela Ken (21 per 1,000), Mahal Magmahal – Esremborak (17; 41,945 reposts), then three Cup of Joe sessions: Hayaan, Hinga, Sandali (14-16). 17 of 144 Reels in 2026 passed 10 per 1,000. Caveat: this is correlation; a Reel shown to more strangers also gets reposted by more of them.

**Q5 Why are comments so rare, and which posts start conversations?**
- Why: every system card predicts comments, but Mosseri left them out of the top three. Comments are where fans name the artists they want (data set 5), but the API won't return another account's comment text (tested 2026-10-21).
- Decision: whether to ask fans something in the caption or a pinned comment ("Who should we invite next?"). It doubles as invite research once NDN shares its comments.
- Measure: comments per 1,000 views (Reels) and per post (others), by caption type.
- Status: Now for counts. Comment text: Phase 2.
- First look (real): 2026 Reels get 0.13 comments per 1,000 views (YouTube sessions 0.42) against 27.7 likes; per post (2025-26) the median is 7 comments on a Reel and 3 on a carousel.

### Relevance: which songs and posts fit NDN's audience?

**Q6 ★ Does Instagram reward the same songs as YouTube and TikTok?**
- Why: YouTube Search and Up next favour songs people already know (YouTube Q5). Instagram doesn't wait for a search: it ranks by the viewer's activity and the reel itself (audio, visuals), so a lesser-known song can do as well if the clip hooks.
- Decision: whether to pick Instagram clips from the YouTube and TikTok winners or give lesser-known songs a chance; which songs deserve a second Reel.
- Measure: index by the song's rank among the artist's Spotify songs (kworb), within the same artist; correlation between a session's Instagram, YouTube and TikTok indexes (same song and artist).
- Status: Now.
- First look (real, Reels at least 14 days old): a song's fame matters much less than on YouTube. Same artist, top-3 Spotify songs vs their other songs: 1.45× the index (32 artists; the top songs win for 23). On YouTube: 9.6×, winning for 50 of 53. By band: #1 song 1.46, #2-5 1.46, #6 and lower 1.69, artists too small for kworb 0.69. A session's Instagram index still goes with its YouTube index (r = 0.45, n 303) and TikTok index (r = 0.54, n 201): when the YouTube session was a 10× hit, its Reel's median index was 2.4.

**Q7 Which series work on Instagram?**
- Why: viewers who enjoy one Cozy Cove Reel get more like it; a series the system and the viewers recognise is easier to recommend.
- Decision: where Instagram effort goes, and whether every caption should name the series.
- Measure: median index by series (read from the caption's brackets), groups of 10+ Reels only.
- Status: Now.
- First look (real, 2025-26): Live at The Cozy Cove 1.63 (n 110), The Cozy Cove Fest 1.62 (17). Live at Alpas La Union 2.28 is too small (9). 239 Reels don't name a series (0.82); they mix post types, so naming the series can't be credited yet.

### Search: can people find NDN on Instagram?

**Q8 Do hashtags and caption words help?**
- Why: Instagram Search matches the typed words to account names, keywords and hashtags, then ranks by how often people in the same country click (Search system card, June 2026). Mosseri: hashtags don't bring reach. Since July 2025 public posts of professional accounts can show up on Google (secondary).
- Decision: a caption template (song, artist, series first; up to 5 hashtags) and whether long hashtag lists are worth typing.
- Measure: index by number of hashtags within the same caption type; which hashtags (series, artist, song, #OPM, #Baguio). Search traffic itself is Phase 2 (Insights; Google Search Console for Instagram since July 2026).
- Status: Now (rough). Phase 2 for search traffic.
- First look (real): the median post went from 0 hashtags in 2025 to 5 in 2026 (#cozycove #OPM #Baguio + artist + song). 39 posts since the reported cap carry 6-9, so the cap isn't applied to NDN's posting tool, or at all. Reels with 4-5 hashtags 1.38 vs none 0.64, but the no-hashtag Reels are older and of other types: compare within caption type before concluding anything.

### Grow: do viewers become followers?

**Q9 Which Reels bring followers?**
- Why: the Reels card predicts "follow the author", using the followers a reel has already earned. Follows per post are owner-only; the account total is public and exact.
- Decision: which artists and post types grow NDN's own audience, the one asset no platform change can take away.
- Measure: each day's follower gain split across that day's posts by their share of views gained (approximate); days with a breakout Reel vs days without.
- Status: New data (daily views), then Wait about 4 weeks.
- First look (real): +1,445 followers from 15 Oct to 21 Oct 2026 (about 250 a day), with 9 new posts.

### Last: does a post keep earning?

**Q10 ★ How fast do posts fade, and do old Reels come back?**
- Why: Feed favours posts people engage with quickly (Mosseri 2023) and Reels and Explore keep testing fresh posts. Unlike YouTube, there's no Search and Up next keeping old posts alive for years.
- Decision: how long to keep pushing a Reel; when to judge a new Reel (day 3? day 7?); re-cutting old hit sessions into new Reels instead of hoping old Reels come back.
- Measure: views gained per day by Reel age; share of the account's daily views from Reels under 30 days, 30 days to 1 year, over 1 year; days to 90% of views; comeback = an old Reel's 7-day gain at least 2× its previous 28-day median.
- Status: likes Now (daily since 2026-10-15). Views: New data, then Wait about 4 weeks for comebacks.
- First look (real, likes gained 15-20 Oct 2026): 26,471 new likes: posts under 30 days old 44%, 30 days to 1 year 56%, over a year 1%. So an Instagram post lives for months, not years (YouTube: 69% of views from sessions over a year old).

### Habits: what NDN controls

**Q11 ★ Teaser before the Premiere or "now streaming" after, and does the slot matter?**
- Why: Feed and Stories favour fresh posts from accounts people interact with, so a teaser an hour before the YouTube Premiere reaches followers while it's news. Mosseri's 2023 explainer doesn't name posting time as a signal.
- Decision: keep the 6 pm teaser for every Premiere; whether the second "now streaming" Reel earns its slot (or should be a Story); event and ticket news as carousels or Stories instead of Reels.
- Measure: index by caption type; index by weekday and hour (2025-26).
- Status: Now.
- First look (real, 2025-26 Reels at least 14 days old): premiere teasers 1.46 (n 145; 126 posted at 6 pm), "now streaming" 1.03 (130), other Reels 0.64 (87), event and ticket Reels 0.50 (14). Teasers also get more likes (31 vs 24 per 1,000 views) and reposts (3.8 vs 3.0). By weekday: Wed 1.20, Fri 1.22 vs Mon 0.86, Tue 0.93, Thu 0.84, Sat 0.85 (Sun 1.25, only 22). Caveats: the teaser goes out first, so the "now streaming" Reel meets people who saw the teaser; Monday is a Premiere day on YouTube, yet Monday Reels do worse (to check).

### Music outcome: why a label is on Instagram

**Q12 Does an Instagram push add Spotify listeners beyond the YouTube session?**
- Why: the end goal is listeners. Each Reel promotes the Premiere and the song.
- Decision: how much effort Instagram deserves next to TikTok and YouTube; whether to add a Spotify link to Stories on Premiere days (caption links aren't clickable).
- Measure: inside the flagship test (YouTube Q12), add the Reel's day-7 index as a second push: do songs whose Reel broke out gain more Spotify streams in the 4 weeks after the Premiere than the YouTube session alone explains? Also: the teaser's day-1 views vs Premiere turnout (YouTube Q10).
- Status: Wait (Spotify history since 2026-10-20; daily Reel views once collected).
- First look: none yet.

**Q13 How do Instagram results feed the invite score?**
- Why: the score (`INVITE_SCORE.md`) gives 15% to "NDN track record" and 15% to "Fan demand"; Instagram should feed both.
- Decision: who to invite next.
- Measure:
  - Track record, Instagram part: median index of the artist's Reels (Q1) and the size-adjusted ratio.
  - Fan demand: reposts per 1,000 views on the artist's Reels (Q4); comments in Phase 2.
  - Momentum: the artist's own Instagram followers and growth (New data: artists' accounts, data set 6).
- Status: index Now, once captions parse properly (only 349 of 635 Reels give a song and artist today). Artist accounts: New data.
- First look (real, artists with 3+ parsed Reels 2024-26, median index): Janine Berdin 40.9 (3 Reels), Cup of Joe 4.5 (7), fitterkarma 4.5 (4), Maki 4.2 (7), Angela Ken 3.0 (4), TJ Monterde 2.1 (4). Cup of Joe also has 3 of the 5 most passed-on Reels (Q4).

**Q14 What should NDN post on Instagram next week?**
- Why: the point of the list: turn answers into a short brief.
- Decision: the week's plan: which clip to cut for each Premiere teaser, which sessions get a second Reel, which old hits to re-cut, captions and hashtags.
- Measure: built from Q1, Q4, Q6, Q10 and Q11; written by the daily Claude routine once those are answered.
- Status: Wait (needs the ★ answers first).

### Phase 2: only with NDN's Instagram Insights

- Reach, split into followers and non-followers; views by surface (Feed, Reels tab, Explore, Stories, profile, Search).
- Average watch time, skip rate and retention per Reel; Trial Reels results.
- Sends (DM shares), shares outside Instagram, saves; profile visits and follows per post; Story link clicks.
- Comment text and DMs (fan requests, data set 5).
- Audience country, city, age and gender; when followers are online.
- Facebook views of crossposted Reels; paid vs organic for boosted posts; how a collab post's reach splits between NDN and the artist.
- Search terms; Google Search Console for Instagram (since July 2026).

This list is also the ask when Vic offers NDN free analyst work.

## What comes next

1. Vic reviews this list: cut, add or reorder questions.
2. Small data fixes first (gap list below; build only after Vic agrees). Adding views and reposts to the daily pull costs no extra API calls, and every day without it is a day of Reel views we can't get back.
3. Answer with data we have: Q1 first (it fixes the Instagram index), then Q6, Q11 and Q4; Q10 and Q9 once daily views run.
4. Then redesign the Instagram page of dashboard v3 so each chart answers one ★ question (with the `dataviz` skill).

## Data

Already collected daily (Edge Function `instagram-snapshot`, pg_cron 09:05 PH, 9 calls): every post's caption, type, time, likes and comments, plus followers, follows and media count. It lands in `raw.instagram_responses` → `staging.instagram_post_snapshot`, `staging.instagram_account_snapshot`, `mart.dim_video` (platform 'Instagram').

Gap list (fields tested 2026-10-21 with a one-off, read-only pull through the same API):

| Gap | Questions | Extract that fills it | Cost |
|---|---|---|---|
| Reel views, daily | Q1, Q4, Q9, Q10, Q12, every per-view rate | Add `view_count` to the daily Business Discovery fields (all 635 Reels return it) plus a column in `staging.instagram_post_snapshot` | No extra calls |
| Reposts, daily | Q4, Q13 | Add `reposts_count` (every post returns it) | No extra calls |
| Facebook part of likes and comments | Caveat checks | Add `total_like_count`, `total_comments_count` | No extra calls |
| Song, artist, series and caption type from the caption | Q6, Q7, Q11, Q13 | SQL: teach `mart.parse_title` the Instagram captions ("<Song> (<Series>) by <Artist> premieres TONIGHT…", "… is now streaming…", "<Artist> performs '<Song>'"). Today many come back empty ("Shelter of the Broken by Ice Seguerra premieres TONIGHT") or wrong (artist "Angela Ken is") | SQL only |
| Reel → YouTube session and Spotify track | Q6, Q12 | SQL view like `staging.youtube_session_spotify` | SQL only |
| Artists' and benchmark Instagram accounts | Q13 Momentum, data set 6 | Business Discovery weekly on each artist's account (Business or Creator accounts only); handles from bios and TikTok mentions | 1 call per account (more for all their posts) |
| Comment text | Q5, data set 5 | Not possible: the API refuses another account's comments (tested). Phase 2 | — |
| Stories, reach, watch time, sends, saves, follows per post, audience | Q3, Q9, Phase 2 list | Not public | — |
| Reel length | Q3 | Not in the API. Skip until Phase 2 | — |
| Other people's posts with #cozycove | Q8 | Hashtag search needs Meta App Review. Skip | — |

## Exercises (about 10 minutes each)

1. In the Supabase SQL editor, from `staging.instagram_post_snapshot`, list the 10 posts that gained the most likes between 2026-10-15 and the latest snapshot (latest likes minus the 2026-10-15 likes). Finished = 10 rows. How many are over 30 days old? Compare with Q10.
2. On your phone, open NDN's latest "premieres TONIGHT" Reel and the "now streaming" Reel of the same session. Write down views and reposts for both. Which would you send to a friend, and why? Check your guess against Q4 and Q11.
3. Count the hashtags on NDN's last 10 posts. How many have more than 5? Q8 says the cap isn't applied to NDN's posts; check whether that has changed.

## Sources

Full list with dates in the skill file `references/instagram.md`. Main ones:

- Mosseri, "Instagram Ranking Explained" (May 2023): https://about.instagram.com/blog/announcements/instagram-ranking-explained
- Mosseri's top three signals (Social Media Today, Jan 2025): https://www.socialmediatoday.com/news/instagram-shares-algorithm-insights-2025/738034/
- Meta system cards for Instagram (Reels, Explore, Feed recommendations, Search): https://transparency.meta.com/features/explaining-ranking/
- Rewarding original creators (Instagram creators blog, Apr 2026): https://creators.instagram.com/blog/rewarding-original-creators-on-instagram/
- Reposts and the Friends tab (Meta, Aug 2025): https://about.fb.com/news/2025/08/new-instagram-features-help-you-connect/
- Your Algorithm (Instagram, Dec 2025, updated Jun 2026): https://about.instagram.com/blog/announcements/reels-algorithm-control
- IG Media fields (`view_count` for Business Discovery): https://developers.facebook.com/docs/instagram-platform/reference/instagram-media
- API updates: reposts, Facebook views in `view_count` (Meta, Apr 2026): https://developers.facebook.com/blog/post/2026/04/22/instagram-api-updates-for-partnerships-metrics-collaboration-and-engagement/
- Philippines: DataReportal Digital 2026: https://datareportal.com/reports/digital-2026-philippines
