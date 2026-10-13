-- STEP 2 (Load): the raw layer.
-- One row per API response, stored untouched as JSONB. Nothing is cleaned here;
-- that happens in staging (Step 3). raw = "what YouTube said, on which day".

create schema if not exists raw;
create schema if not exists staging;
create schema if not exists mart;

-- Every API response (channel.json, videos_001 ... videos_021) for every day.
create table if not exists raw.youtube_responses (
    id            bigint generated always as identity primary key,
    snapshot_date date        not null,               -- UTC date of the run
    file_name     text        not null,               -- 'channel', 'videos_001', ...
    extracted_at  timestamptz not null,
    request_url   text,                               -- key already replaced by REDACTED
    payload       jsonb       not null,               -- exactly what the API returned
    loaded_at     timestamptz not null default now(),
    unique (snapshot_date, file_name)                 -- a day can't be loaded twice
);

-- One row per daily run: the database version of _SUCCESS.json.
create table if not exists raw.youtube_runs (
    snapshot_date    date primary key,
    extracted_at     timestamptz not null,
    channel_id       text        not null,
    videos           int         not null,
    playlist_pages   int         not null,
    quota_units_used int         not null,
    triggered_by     text                              -- 'pg_cron', 'github', 'manual'
);

-- raw is not exposed through the Supabase API; RLS with no policies blocks
-- anon/authenticated access anyway. The postgres role (used by the function) bypasses it.
alter table raw.youtube_responses enable row level security;
alter table raw.youtube_runs      enable row level security;
