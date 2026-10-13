-- STEP 2b: run the youtube-snapshot Edge Function every day from inside Supabase.
-- pg_cron = a clock inside Postgres. pg_net = lets Postgres make HTTP calls.
-- Vault = encrypted storage for secrets, readable only by privileged roles.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- Secrets (run once; values are not stored in this file):
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--   select vault.create_secret('<random string>', 'ndn_cron_secret');

-- 01:00 UTC = 09:00 Philippine time. YouTube quota resets 07:00/08:00 UTC, so
-- the full 10,000 units are free at this hour.
select cron.schedule(
    'ndn-youtube-daily',
    '0 1 * * *',
    $$
    select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
               || '/functions/v1/youtube-snapshot?by=pg_cron',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 150000
    );
    $$
);

-- Useful checks:
--   select * from cron.job;                                             -- the schedule
--   select * from cron.job_run_details order by start_time desc limit 5; -- did it fire?
--   select id, status_code, content from net._http_response order by created desc limit 5;
--   select * from raw.youtube_runs order by snapshot_date desc;          -- did it load?
