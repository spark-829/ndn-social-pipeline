# Synthetic 10-month backfill (YouTube + TikTok)

> **Synthetic data.** Everything in the Supabase `synthetic` schema is invented. It is not real Nine Degrees
> North data. It exists so the SQL transforms, analysis and dashboard can be built and tested on a long time
> series before the real daily snapshots have built up that much history. Real data lives only in `raw`.

## What was generated (seed `ndn-v1`, built 2026-10-14)

| Table | Rows | Covers |
|---|---|---|
| `synthetic.youtube_video_daily` | 273,358 | 1,015 videos, 2025-12-12 to 2026-10-11 |
| `synthetic.tiktok_video_daily` | 225,189 | 968 videos, 2025-12-13 to 2026-10-12 |
| `synthetic.youtube_channel_daily` | 304 | subscribers, total views, video count |
| `synthetic.tiktok_account_daily` | 304 | followers, hearts, video count |

Each window ends the day before the first real snapshot (YouTube 2026-10-12, TikTok 2026-10-13), so synthetic
and real data never overlap. Size: about 112 MB.

## How it imitates the real data

1. **Real anchors.** Each video's history ends exactly on its real view, like and comment counts from the first
   real snapshot, and starts at its real upload time. No rows exist before a video was uploaded, which is why
   early dates hold fewer videos.
2. **Curves measured on NDN's own data.** The real day-over-day growth (2026-10-13 to 10-14, about 1,900 videos)
   was measured by video age:

   | Age | YouTube full | YouTube Shorts | TikTok |
   |---|---|---|---|
   | 0-7 days | 13.9%/day | 8.9% | 13.2% |
   | 7-30 days | 3.1% | 1.5% | 0.7% |
   | 30-90 days | 0.93% | 0.69% | 0.10% |
   | 90-365 days | 0.22% | 0.13% | ~0 |
   | 1 year + | 0.054% | 0.037% | ~0 |

   - YouTube: growth x age stays about constant, which is the signature of a **power law**:
     `views(age) = real views x (age / age at anchor)^k`, k around 0.45 (full) or 0.28 (Shorts), varied per video.
   - TikTok: a **burst that fades** (about 4 days) plus a small tail:
     `g(age) = (1 - w)(1 - e^(-age/tau)) + w * sqrt(age / age at anchor)`.
3. **Daily noise on gains, not totals.** Each day's gain varies (+-25% YouTube, +-35% TikTok), and totals are
   built by subtracting later gains from the real count. Totals therefore only rise and meet the real number
   without a jump.
4. **Platform quirks kept.** TikTok counts of 10,000+ are rounded down to 3 digits, as TikTok shows them;
   YouTube subscribers likewise; hidden YouTube like counts stay empty.
5. **Accounts add up.** Channel views, subscribers, followers and hearts are rebuilt from the videos each day.
6. **Repeatable.** Random numbers come from a hash of (seed, video id, date), so the same seed rebuilds identical
   data.

## Checks that passed

- 0 days where a video's views go down; 0 rows before upload; 0 values above the real count.
- Synthetic growth by age (last synthetic day) vs real: YouTube full 2.6% / 0.78% / 0.19% / 0.059% against real
  3.1% / 0.93% / 0.22% / 0.054% for the 7-30d, 30-90d, 90-365d and 1y+ groups. The first week is noisier because it
  rests on very few videos.
- Channel total views 1.56B -> 2.17B over the window (about 2M a day), against a real recent pace of about
  3M a day. TikTok followers 170k -> 318k.

## Limits (say these when you present it)

- Calibrated on one day of real growth. Weekday effects, viral spikes, deleted videos and algorithm changes are
  not modelled.
- Subscribers and followers are assumed to grow in step with views.
- Use it to build and test the pipeline and dashboard. Do not report findings from it as facts about NDN.

## Rebuild

Files: `sql/004_synthetic_backfill.sql` (tables, helpers, full model notes) and `sql/004d_synthetic_batched.sql`
(the batched builders). Building everything in one statement ran out of memory on the free tier, so it runs in
batches of about a tenth of the videos:

```sql
-- empty the four synthetic tables first (manual step, on purpose), then:
select synthetic.build_youtube('ndn-v1', 0, 10);   -- repeat for buckets 0..9
select synthetic.build_tiktok('ndn-v1', 0, 10);    -- repeat for buckets 0..9
select synthetic.build_accounts('ndn-v1');
```

## Exercises

1. Pick one Cozy Cove video and chart its synthetic `views` by `snapshot_date`. Where is the curve steepest, and why?
2. Write a query that finds the day each video crossed 100,000 views. Which upload month crossed fastest?
3. Compare the median daily gain of Shorts vs full videos older than one year. Does it match the table above?
4. Rebuild with seed `ndn-v2` into a scratch copy and compare one video's history. What changed, and what stayed
   the same (hint: the start and end points)?
5. Explain in two sentences why adding noise to the totals (instead of the gains) would have produced flat days
   followed by jumps.
