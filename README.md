# Nine Degrees North: social media ELT pipeline

Independent analysis of public data. Not affiliated with Nine Degrees North.

Nine Degrees North (NDN) is a Baguio-based record label best known for the YouTube series **Live at The Cozy Cove**. This pipeline collects public data from their platforms every day, loads it into Supabase (Postgres), models it in SQL, analyses it in pandas and shows it in Tableau Public.

```
YouTube Data API ─┐
Instagram (Business Discovery) ─┤  EXTRACT   raw JSON    LOAD     TRANSFORM (SQL)      ANALYSE    SHOW
TikTok (yt-dlp) ─┤ ───────────▶ (untouched) ─────▶ raw ─▶ staging ─▶ mart ─▶ pandas ─▶ Tableau Public
Spotify streams (kworb.net) ─┘        daily snapshot (Supabase pg_cron + GitHub Actions)
```

## Phase 1: public data only
| Step | What | Status |
|---|---|---|
| 1 | Extract YouTube (`extract_youtube.py`) | done; daily since 2026-10-12 |
| 2 | Load raw JSON into Supabase `raw` schema (Edge Function + pg_cron) | done |
| 3 | SQL: parse titles into artist/song, staging views, mart tables | next |
| 4 | Spotify streams from kworb.net | |
| 5 | Instagram via Business Discovery | |
| 6 | TikTok via profile JSON + yt-dlp (`extract_tiktok.py`) | done; daily since 2026-10-13 |
| 7 | pandas analysis + Tableau Public dashboard | |
| 8 | GitHub Actions daily schedule | done (TikTok + YouTube backup) |

## Synthetic history (clearly labelled)
Real snapshots only start in October 2026, so the Supabase `synthetic` schema holds a **synthetic** 10-month
backfill (Dec 2025 to Oct 2026) for YouTube and TikTok. It is invented data, kept apart from `raw`, built from
each video's real upload date and real current counts with growth curves measured on the real daily data.
It is for building and testing the transforms and dashboard, not for conclusions about NDN.
Details, checks and exercises: [SYNTHETIC_BACKFILL.md](SYNTHETIC_BACKFILL.md).

Phase 2 (after NDN grants access): YouTube Analytics API, Instagram/Facebook insights, TikTok Display API.

## Setup
```
pip install -r requirements.txt
copy .env.example .env      # then paste your YouTube API key into .env
python test_extract_youtube.py
python extract_youtube.py
```
