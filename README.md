# Nine Degrees North: social media ELT pipeline

Independent analysis of public data. Not affiliated with Nine Degrees North.

Nine Degrees North (NDN) is a Baguio-based record label best known for the YouTube series **Live at The Cozy Cove**. This pipeline collects public data from their platforms every day, loads it into Supabase (Postgres), models it in SQL, analyses it in pandas and shows it in Tableau Public.

```
YouTube Data API ─┐
Instagram (Business Discovery) ─┤  EXTRACT   raw JSON    LOAD     TRANSFORM (SQL)      ANALYSE    SHOW
TikTok (Apify) ─┤ ───────────▶ (untouched) ─────▶ raw ─▶ staging ─▶ mart ─▶ pandas ─▶ Tableau Public
Spotify streams (kworb.net) ─┘        daily snapshot, scheduled with GitHub Actions
```

## Phase 1: public data only
| Step | What | Status |
|---|---|---|
| 1 | Extract YouTube (`extract_youtube.py`) | written, tests pass, not yet run with a real key |
| 2 | Load raw JSON into Supabase `raw` schema | |
| 3 | SQL: parse titles into artist/song, staging views, mart tables | |
| 4 | Spotify streams from kworb.net | |
| 5 | Instagram via Business Discovery | |
| 6 | TikTok via Apify | |
| 7 | pandas analysis + Tableau Public dashboard | |
| 8 | GitHub Actions daily schedule | |

Phase 2 (after NDN grants access): YouTube Analytics API, Instagram/Facebook insights, TikTok Display API.

## Setup
```
pip install -r requirements.txt
copy .env.example .env      # then paste your YouTube API key into .env
python test_extract_youtube.py
python extract_youtube.py
```
