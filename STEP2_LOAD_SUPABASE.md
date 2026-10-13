# Step 2: Load (and automate Extract) inside Supabase

## What runs every day
```
01:00 UTC (09:00 PH)  pg_cron  ──pg_net POST──▶  Edge Function youtube-snapshot
                                                   │ 1 channel call
                                                   │ 21 playlist pages (ID lookup only)
                                                   │ 21 video batches
                                                   ▼
                                    raw.youtube_responses  (22 rows/day, JSONB untouched)
                                    raw.youtube_runs       (1 row/day = run summary)
03:00 UTC  GitHub Actions ──POST──▶ same function → "already_done" (keep-alive + backup)
```
- **pg_cron**: a clock inside Postgres. `cron.schedule(name, '0 1 * * *', sql)`.
- **pg_net**: lets SQL send HTTP requests. Responses are kept 6 hours in `net._http_response`.
- **Vault**: encrypted secrets (`project_url`, `ndn_cron_secret`). The YouTube key is an Edge Function secret instead.
- **Edge Function**: `supabase/functions/youtube-snapshot/index.ts`, the TypeScript twin of `extract_youtube.py`.
- **All-or-nothing**: the 22 rows + run row are inserted in one transaction. A crash leaves no half day.
- **Idempotent**: if `raw.youtube_runs` already has today, it returns without calling YouTube.

Files: `sql/001_raw_schema.sql`, `sql/002_schedule.sql`, `.github/workflows/daily.yml` (youtube-backup job).

## Why still "raw"
Nothing is cleaned on the way in. Counts stay strings, titles stay messy. If a transform has a bug
later, we fix the SQL and rebuild from raw; the original answers from YouTube are never lost.

## Check it (Supabase dashboard → SQL Editor)
```sql
select * from raw.youtube_runs order by snapshot_date desc;                 -- one row per day
select * from cron.job_run_details order by start_time desc limit 5;        -- did cron fire?
select status_code, left(content,200) from net._http_response order by created desc limit 5;
```

## Exercises
1. Run the first query tomorrow after 9 am. What does `triggered_by` say?
2. Count today's videos straight from JSON:
   `select sum(jsonb_array_length(payload->'items')) from raw.youtube_responses where file_name like 'videos_%' and snapshot_date = current_date;`
3. Pull one field out of JSONB: the channel's subscriber count.
   Hint: `payload->'items'->0->'statistics'->>'subscriberCount'` where `file_name = 'channel'`.
   What's the difference between `->` and `->>`?
4. Why does the function check `raw.youtube_runs` before calling YouTube? What would happen
   without that check when GitHub calls it at 03:00?
5. Why is the snapshot date UTC and not Philippine time? (Hint: what date would a 07:30 PH run get?)
