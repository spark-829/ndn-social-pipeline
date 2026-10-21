-- 024_artist_instagram.sql (2026-10-21, INSTAGRAM_QUESTIONS.md gap list row 6: Q13 Momentum, data set 6)
-- Artists' own Instagram accounts, weekly.
--   Usernames: the artist's Spotify page lists its social links (profile.externalLinks); NDN's Instagram
--   captions don't @-tag artists (1 of 899 has an @), and photo tags are refused by the API.
--   raw.artist_social      every social link from Spotify (one-off pull 2026-10-21, then the weekly
--                           extract_spotify.py keeps profile.externalLinks in its snapshot)
--   raw.artist_instagram_weekly   Business Discovery: followers, posts (Business/Creator accounts only)
--   mart.artist_instagram_growth  followers now vs 4 and 8 weeks ago

create table if not exists raw.artist_social (
  spotify_id  text not null,
  platform    text not null,                 -- INSTAGRAM, FACEBOOK, TWITTER, WIKIPEDIA (Spotify's names)
  url         text not null,
  fetched_at  timestamptz not null default now(),
  primary key (spotify_id, platform, url)
);
alter table raw.artist_social enable row level security;

-- one username per artist: from the latest Spotify snapshot if it has links, else the one-off pull
create or replace view staging.artist_instagram as
with links as (
  (select distinct on (s.spotify_id) s.spotify_id, l->>'url' as url
   from raw.spotify_artist_snapshot s
   cross join lateral jsonb_array_elements(s.payload->'profile'->'externalLinks') l
   where l->>'name' = 'INSTAGRAM'
   order by s.spotify_id, s.snapshot_date desc)
  union all
  select r.spotify_id, r.url from raw.artist_social r where r.platform = 'INSTAGRAM'
)
select distinct on (spotify_id) spotify_id,
       lower((regexp_match(url, 'instagram\.com/([A-Za-z0-9._]+)'))[1]) as username
from links
where url ~ 'instagram\.com/[A-Za-z0-9._]+'
order by spotify_id;

create table if not exists raw.artist_instagram_weekly (
  snapshot_date date not null,
  spotify_id    text not null,
  username      text not null,
  found         boolean not null,            -- false = personal account or wrong username (Business Discovery refuses)
  followers     bigint,
  posts         bigint,
  error         text,
  fetched_at    timestamptz not null default now(),
  primary key (snapshot_date, spotify_id)
);
alter table raw.artist_instagram_weekly enable row level security;

create or replace view mart.artist_instagram_growth as
with w as (
  select spotify_id, username, snapshot_date, followers from raw.artist_instagram_weekly where found
), latest as (
  select distinct on (spotify_id) * from w order by spotify_id, snapshot_date desc
)
select l.spotify_id, l.username, l.snapshot_date, l.followers,
       l.followers - (select w.followers from w where w.spotify_id = l.spotify_id and w.snapshot_date <= l.snapshot_date - 28
                      order by w.snapshot_date desc limit 1) as growth_4w,
       l.followers - (select w.followers from w where w.spotify_id = l.spotify_id and w.snapshot_date <= l.snapshot_date - 56
                      order by w.snapshot_date desc limit 1) as growth_8w
from latest l;

-- weekly: Wed 09:30, 10:30, 11:30, 12:30 PH, up to 60 artists per call (Meta allows ~200 calls an hour for
-- the app, shared with the daily NDN + benchmark pulls). Calls with nothing due exit at once.
do $$
declare h int;
begin
  foreach h in array array[1, 2, 3, 4] loop
    perform cron.schedule('ndn-artist-ig-weekly-' || h, '30 ' || h || ' * * 3', $c$
      select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
               || '/functions/v1/benchmarks?step=artist_ig&limit=60&by=pg_cron',
        headers := jsonb_build_object('Content-Type', 'application/json',
            'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
        body := '{}'::jsonb, timeout_milliseconds := 150000);
    $c$);
  end loop;
end $$;
