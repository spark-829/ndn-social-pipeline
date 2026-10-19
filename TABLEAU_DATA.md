# Tableau Public data (Step 7 input)

`py export_tableau.py` writes three CSV files to `tableau/` from the Supabase `mart` views
(`sql/005_staging_mart.sql`, title parser `sql/005b_parse_title_v2.sql`). Re-run it whenever you want fresh data,
then in Tableau use **Data > Refresh** (Tableau Public cannot connect to Postgres, only to files or Google Sheets).

> Dates before the first real snapshot (YouTube 2026-10-12, TikTok 2026-10-13) are **synthetic**. Instagram is real only (from 2026-10-15) and has no views: compare it on likes and comments.
> Every fact row has `data_source` = `real` or `synthetic`. Show it on the dashboard (colour or a filter) and
> say so in the dashboard description. See [SYNTHETIC_BACKFILL.md](SYNTHETIC_BACKFILL.md).

## The star schema

```
                 dim_video  (one row per video)
                 platform + video_id
                        |
        +---------------+
        |
fact_video_daily   (one row per video per day)          fact_account_daily  (one row per platform per day)
platform + video_id + snapshot_date                      platform + snapshot_date
```

**In Tableau:** connect to `dim_video.csv`, then drag `fact_video_daily.csv` onto the canvas and create a
**relationship** on `platform = platform` AND `video_id = video_id` (relationships, not joins: Tableau then only
combines the tables a chart needs). Add `fact_account_daily.csv` as a separate data source.

## Columns

### dim_video.csv
| Column | Meaning |
|---|---|
| platform | YouTube, TikTok or Instagram |
| video_id, url | ID and link |
| title | full title (YouTube) or caption (TikTok, Instagram) |
| published_at | upload time, UTC |
| published_date_ph, published_weekday_ph, published_weekday_num, published_hour_ph | upload time in Philippine time (Q4: best upload day/time) |
| duration_sec, format | length; `Short (<=60 s)`, `Full video`, `TikTok clip`, `Instagram Reel`, `Instagram post` or `Instagram carousel` (Instagram has no duration) |
| series | `Live at The Cozy Cove`, `The Cozy Cove Fest`, `Live at Session Road`, `Alpas La Union`, `Harana sa Manila`, `Taped Sessions`, `New Clark City Stadium`, `Other live shows`, `Other sessions`, `Other releases`, `Other` |
| session, song, artist | parsed from the title |
| song_key | normalised `song|artist`, matches a TikTok clip to its YouTube session (Q3) |
| mentions_cozy_cove | title or caption mentions Cozy Cove |
| latest_views/likes/comments, latest_snapshot | most recent real counts |

### fact_video_daily.csv
| Column | Meaning |
|---|---|
| snapshot_date | the day (snapshot taken 01:00 UTC = 9 am PH) |
| data_source | `real` or `synthetic` |
| views, likes, comments, shares, saves | running totals that day (shares/saves TikTok only; Instagram views blank, likes blank when NDN hid them) |
| views_gained, likes_gained | gain since the previous day (blank on a video's first row). A few **real** gains are negative: YouTube removes invalid views after audits and TikTok's 3-digit rounding can step down. Keep them; they are real platform behaviour |
| days_since_upload | age of the video that day (Q2: first 7 / 30 days) |

### fact_account_daily.csv
| Column | Meaning |
|---|---|
| followers | YouTube subscribers (rounded by YouTube to 3 digits) or TikTok/Instagram followers |
| followers_gained, total_views, views_gained | daily change; total_views is YouTube only |
| video_count, hearts | videos/posts on the account (Instagram: media_count, which the API reports as 869 while 891 posts come back); TikTok total likes |

### dim_video.csv: real "per day" measures (added 2026-10-17)
| Column | Meaning |
|---|---|
| age_days | days from upload to latest_snapshot (minimum 1) |
| views_per_day, likes_per_day | latest count / age_days. **Real**, and fair between old and new videos |
| perf_per_day | views_per_day, or likes_per_day for Instagram (no views) |
| engagement_rate | (likes + comments) / views |
| vs_series_median | perf_per_day / median of the same platform + series. 2.0 = twice a typical video in that series. Adjusts for size |

### song_compare.csv (Q3)
One row per `song_key`: `youtube_views`, `tiktok_views`, `instagram_likes`, video counts per platform, `is_cozy_cove`.
254 songs have both YouTube and TikTok views.

## Dashboard v2 (built by code, 2026-10-19)

Rebuild: `py export_tableau.py` then `py build_tableau_workbook.py` -> `tableau/NDN_dashboard.twbx`
(CSV -> .hyper extracts with `tableauhyperapi`; Tableau Public refuses live CSV links). v1 builder backed up in the
session scratchpad only; git history has it once committed.

New feeds (sql/012_dashboard_v2.sql, real snapshots only): `tiktok_video.csv` (one row per TikTok video: performance
index, per-1,000 rates, share/save quarter, caption type, sound type, hashtag group, 7-day gain), `tiktok_hashtag.csv`
(tags on 10+ posts), `platform_scorecard.csv` (followers, 7-day change, views/likes gained, best post per platform).
Edge Function `tableau-feed` serves them as `tiktok`, `hashtags`, `scorecard`; the Apps Script copies them as tabs.

| Dashboard | Size | What |
|---|---|---|
| 0 Executive | 1200x900 | title, daily headline, platform cards (followers, 7-day change, views/likes gained), Actions (daily Claude text), best post this week, TikTok breakout % by month, follower growth % |
| 1 TikTok | 1200x2900 scroll | how-to-read note, 3 cards, sections Attract (Q1, Q14), Engage + Retain (Q4 x2, Q5, Q3), Relevance (Q6, Q7, Q15 x2), Habits + Long life (Q11 x3, Q10, best recent), Not answerable yet (Q2, Q8, Q9, Q12, Q13, Q16, Q17, Phase 2) |
| 2 YouTube | 1200x800 | card, best post, top videos by views/day, views by series, weekday, full vs Shorts (simple version) |
| 3 Instagram | 1200x800 | card, followers (real), format, top posts by likes/day (simple version) |

Design research (2026-10-19): popular Tableau Public executive vizzes (Viz of the Day business dashboards, "KPI
Overview", Pradeep Kumar G's HR/Web traffic) share: 5-7 KPIs max, BAN cards on top that show change, not just the
value; trend in the middle, breakdowns below; neutral base with one accent; every chart subtitle states its question.
TikTok bars: white = beats the typical post (median index >= 1), gray = falls short.

Design (dataviz skill): dark NDN black/white theme, page `#0d0d0d`, cards `#1a1a19`; white = highlight, gray = context;
platform colours YouTube `#3987e5`, TikTok `#d95926`, Instagram `#199e70` (validated all-pairs on the dark surface).
Chart titles stay neutral; findings live only in the daily text so no number goes stale. Hour-of-day was dropped:
85% of uploads go out at 7 pm. Story (dashboards 0-3) is made by hand in Tableau.

### Daily text and auto-refresh
- `mart.insight_facts` (sql/008): today's numbers as one JSON row. Routine "NDN dashboard insights"
  (trig_01UDEZgHbGZRyp3rSHRrx4GB, 15:00 PH) writes 7 sentences into `mart.insights` from those numbers only.
- Edge Function `tableau-feed` serves account / video / songs / insights; Google Apps Script (`google_sheets/`)
  copies them into the Sheet "NDN dashboard data" at 16:00 PH; Tableau Public syncs from the Sheet daily.
- Switching the workbook to the Sheet (by hand, needs Google sign-in): Data > New Data Source > **Google Drive** >
  NDN dashboard data > tab; then on a worksheet (not a dashboard) Data > Replace Data Source, once per source.
  Field captions in the generator match the connector ("Youtube Views"), so fields stay linked.
  Rebuilding the twbx brings back the CSV sources, so finish design changes before swapping.

Exercise: on dashboard 2, compare the top 5 by `views_per_day` with the top 5 by `vs_series_median`. Which list
would you show NDN's marketing team, and why?
## Dashboard v3 plan (agreed with Vic 2026-10-20; build after all data sets are done)

**Platform colors** (every chart that shows platforms). Vic asked for TikTok black, YouTube red, Instagram pink; adjusted so they work on the dark cards (#1a1a19) and pass `validate_palette.js --mode dark --pairs all`:
- TikTok `#00a0d0` (TikTok's cyan accent; black is invisible on the dark cards)
- YouTube `#e8302a`
- Instagram `#d6249f` (magenta-pink; brand pink #e1306c is too close to red, normal-vision ΔE 10 < 15)
- Cyan vs pink is a WARN for deuteranopia (ΔE 7.8), legal only with platform name labels on or beside every mark: always label.

**New charts** (data set 1 onwards):
1. Executive: "Trending now" table: NDN artists in Spotify PH weekly top 200, rank, change, streams, Action (boost video + post clip / check unused footage). `staging.trend_spotify_ph_ndn` + `music_catalog_status`.
2. Top 10 to invite: ranked table with the score and its parts as small bars (see `INVITE_SCORE.md`).
3. Unused songs per artist: bar, posted vs not posted, click to list songs (hide merged Deezer profiles, filter intros/live versions).
4. Fresh vs older song: TikTok performance index dot plot by song age at posting.
5. After 4-8 weeks of history: rising songs (weekly streams lines) and Q16 (NDN post week marked on the song's streams line).
6. Artist listener cities: top 5 Spotify cities per artist (bar), Baguio/Metro Manila highlighted, for show location and lineup.

**Dashboard 4, the 5th page (later): Benchmark.** Weekly YouTube stats of comparable PH live-session channels vs NDN, indexed to 100 at the first week (one axis, no dual axis).

**Demographics:** NDN's own audience (age, gender, city, returning viewers) is not public; it needs YouTube Analytics through NDN's account (Phase 2). Public now: each artist's top 5 Spotify cities (data set 3).
