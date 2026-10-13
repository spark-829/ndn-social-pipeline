-- STEP 6 (Load): raw TikTok snapshots, same pattern as YouTube.
-- Filled by the tiktok-ingest Edge Function, which GitHub Actions calls daily.

create table if not exists raw.tiktok_responses (
    id            bigint generated always as identity primary key,
    snapshot_date date        not null,               -- UTC date of the scrape
    file_name     text        not null,               -- 'profile' or 'videos'
    extracted_at  timestamptz not null,
    source        text,                               -- 'yt-dlp 2026.08.19', 'tiktok.com profile page ...'
    request_url   text,
    payload       jsonb       not null,               -- untouched (minus expiring thumbnail URLs)
    loaded_at     timestamptz not null default now(),
    unique (snapshot_date, file_name)
);

create table if not exists raw.tiktok_runs (
    snapshot_date date primary key,
    extracted_at  timestamptz not null,
    username      text        not null,
    videos        int         not null,
    followers     bigint,
    ytdlp_version text,
    triggered_by  text                                 -- 'github', 'manual'
);

alter table raw.tiktok_responses enable row level security;
alter table raw.tiktok_runs      enable row level security;
