# Google Sheets bridge (Tableau Public auto-refresh)

Tableau Public cannot connect to Supabase, but it can refresh daily from a Google Sheet. Daily flow (PH time):

| Time | What | Where |
|---|---|---|
| 09:00 to ~14:00 | YouTube, Instagram, TikTok snapshots land | pg_cron, GitHub Actions |
| 15:00 | Claude routine "NDN dashboard insights" reads `mart.insight_facts`, writes 7 sentences to `mart.insights` | claude.ai routine trig_01UDEZgHbGZRyp3rSHRrx4GB |
| 16:00 | Apps Script `refreshAll` copies 4 tables into this Sheet | Google Apps Script |
| daily | Tableau Public "Keep data in sync" refreshes the published workbook | Tableau Public |

Data comes from the Edge Function `tableau-feed` (`supabase/functions/tableau-feed`), protected by the same
`x-cron-secret` as the other functions. Tabs: `account`, `video`, `songs`, `insights`, `status`.

## Setup (once)
1. Create a new Google Sheet named `NDN dashboard data` (sheets.new).
2. Extensions > Apps Script. Replace the code with `ndn_feed.gs`. Save.
3. Project Settings (gear): Time zone `(GMT+08:00) Manila`. Under Script Properties add
   `FEED_URL` = `<SUPABASE_URL from .env>/functions/v1/tableau-feed` and `FEED_SECRET` = `NDN_CRON_SECRET` from `.env`.
   Never paste these in chat or commit them.
4. Editor: choose function `setup`, Run, allow access. The Sheet gets 4 tabs and `status` shows the row counts.
5. Tableau Public: open `tableau/NDN_dashboard.twbx`, then for each data source: Data > New Data Source >
   Google Sheets > `NDN dashboard data` > the matching tab, and Data > Replace Data Source (old CSV source ->
   new Sheet source). Publish with **Keep data in sync** ticked.
