-- STEP 5 (Extract + Load): raw Instagram snapshots, same pattern as YouTube.
-- Filled daily by the instagram-snapshot Edge Function, which calls Meta's
-- Business Discovery API (public data of another Business/Creator account:
-- followers, media count, and per post likes, comments, caption, timestamp).
-- Not available this way: views, reach, saves, stories (need NDN's own login).

create table if not exists raw.instagram_responses (
    id            bigint generated always as identity primary key,
    snapshot_date date        not null,               -- UTC date of the run
    file_name     text        not null,               -- 'media_001', 'media_002', ... (page 1 also holds the profile)
    extracted_at  timestamptz not null,
    request_url   text,                               -- token removed
    payload       jsonb       not null,               -- exactly what the API returned
    loaded_at     timestamptz not null default now(),
    unique (snapshot_date, file_name)
);

create table if not exists raw.instagram_runs (
    snapshot_date date primary key,
    extracted_at  timestamptz not null,
    username      text        not null,
    posts         int         not null,               -- posts returned
    media_count   int,                                 -- posts the profile says it has
    followers     bigint,
    api_calls     int         not null,
    triggered_by  text                                 -- 'pg_cron', 'github', 'manual'
);

alter table raw.instagram_responses enable row level security;
alter table raw.instagram_runs      enable row level security;

-- Secrets: Edge Function secrets IG_ACCESS_TOKEN (non-expiring Page token) and
-- IG_USER_ID (Vic's own IG Business account, which makes the call), set from .env
-- with the Supabase Management API; never stored in this file.

-- 01:05 UTC = 09:05 Philippine time, just after YouTube.
select cron.schedule(
    'ndn-instagram-daily',
    '5 1 * * *',
    $$
    select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
               || '/functions/v1/instagram-snapshot?by=pg_cron',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 150000
    );
    $$
);

-- Checks:
--   select * from raw.instagram_runs order by snapshot_date desc;
--   select id, status_code, content from net._http_response order by created desc limit 5;
