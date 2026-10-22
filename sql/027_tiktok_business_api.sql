-- STEP 6b: TikTok official data (TikTok API for Business, "TikTok accounts" scope).
-- Only works for accounts that authorize the app (NDN, or Vic's own Business account for testing).
-- Two Edge Functions use these tables:
--   tiktok-oauth-callback    -> sign-in link + saves the account's tokens
--   tiktok-business-snapshot -> daily job: refresh token if needed, pull account + every video
-- The public-page scraper (raw.tiktok_*) keeps running; this is the official, owner-authorized layer.

-- Tokens are secrets. RLS on with no policies + revoke = only the service role / postgres can read them.
create table if not exists raw.tiktok_api_tokens (
    open_id                text        primary key,     -- TikTok's ID for the authorized account (= business_id)
    username               text,
    display_name           text,
    access_token           text        not null,
    refresh_token          text        not null,
    scope                  text,
    access_expires_at      timestamptz not null,
    refresh_expires_at     timestamptz,
    authorized_at          timestamptz not null default now(),
    updated_at             timestamptz not null default now(),
    status                 text        not null default 'active',   -- 'active' | 'refresh_failed' | 'revoked'
    last_error             text
);

-- One-time "state" values for the sign-in link (stops someone forging a callback).
create table if not exists raw.tiktok_api_oauth_state (
    state      text        primary key,
    created_at timestamptz not null default now()
);

-- Untouched API responses, one row per endpoint call per day.
create table if not exists raw.tiktok_api_responses (
    id            bigint generated always as identity primary key,
    snapshot_date date        not null,
    open_id       text        not null,
    endpoint      text        not null,          -- 'business/get' | 'business/video/list'
    page          int         not null default 1,
    extracted_at  timestamptz not null,
    request_fields jsonb,                         -- which fields we asked for
    payload       jsonb       not null,           -- exactly what TikTok returned
    loaded_at     timestamptz not null default now(),
    unique (snapshot_date, open_id, endpoint, page)
);

create table if not exists raw.tiktok_api_runs (
    snapshot_date date        not null,
    open_id       text        not null,
    username      text,
    status        text        not null,          -- 'ok' | 'error'
    videos        int,
    pages         int,
    followers     bigint,
    error         text,
    triggered_by  text,
    finished_at   timestamptz not null default now(),
    primary key (snapshot_date, open_id)
);

alter table raw.tiktok_api_tokens      enable row level security;
alter table raw.tiktok_api_oauth_state enable row level security;
alter table raw.tiktok_api_responses   enable row level security;
alter table raw.tiktok_api_runs        enable row level security;
revoke all on raw.tiktok_api_tokens, raw.tiktok_api_oauth_state from anon, authenticated;

-- Invite code for the sign-in link (run once, value not stored in this file):
--   select vault.create_secret('<long random string>', 'tiktok_oauth_invite');
-- Sign-in link to send to the account owner:
--   https://<project-ref>.supabase.co/functions/v1/tiktok-oauth-callback?invite=<that string>

-- ---------------------------------------------------------------------------
-- Run this block AFTER the first account has authorized (otherwise the job just reports "no accounts").
-- 01:30 UTC = 09:30 PH, after the YouTube (01:00) and scraper jobs.
-- select cron.schedule(
--     'ndn-tiktok-api-daily',
--     '30 1 * * *',
--     $$
--     select net.http_post(
--         url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
--                || '/functions/v1/tiktok-business-snapshot?by=pg_cron',
--         headers := jsonb_build_object(
--             'Content-Type', 'application/json',
--             'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')
--         ),
--         body := '{}'::jsonb,
--         timeout_milliseconds := 150000
--     );
--     $$
-- );

-- Useful checks:
--   select open_id, username, status, access_expires_at, refresh_expires_at, last_error from raw.tiktok_api_tokens;
--   select * from raw.tiktok_api_runs order by snapshot_date desc limit 10;
--   select endpoint, page, payload->>'code' as code, payload->>'message' as message
--     from raw.tiktok_api_responses where snapshot_date = current_date order by endpoint, page;
