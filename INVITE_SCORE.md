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
