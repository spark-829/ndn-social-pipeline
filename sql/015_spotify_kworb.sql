-- 015: Spotify artist pages + kworb (2026-10-20). Data set 3, Step 4, Q13.
-- Weekly, by extract_spotify.py -> Edge Function spotify-weekly.
--   1. Which Spotify artist is which NDN artist (raw.spotify_artists): from the kworb PH chart's
--      links, links in TikTok bios, or a name search confirmed by an NDN song. Vic checks doubtful ones.
--   2. Spotify artist page (logged-out web player, unofficial): monthly listeners, followers,
--      world rank, top 5 cities with listener counts, top 10 tracks with play counts.
--   3. kworb.net artist page: every song's total and daily Spotify streams. Only artists kworb
--      tracks have a page (small artists get 404, saved as found = false).
-- The Spotify Web API is not used: since Feb 2026 it needs Premium and dropped followers/popularity.
-- Not untouched in two places, to save space: the Spotify payload keeps only the fields below,
-- and kworb pages are parsed to rows by the script (the HTML is mostly ads and menus).

------------------------------------------------------------------ raw
-- One row per Spotify artist we follow. match_type: kworb_chart | bio_link | confirmed_by_song |
-- exact | shared_name | manual. active = false: not scraped (doubtful, waiting for Vic, or wrong).
create table if not exists raw.spotify_artists (
  spotify_id      text primary key,
  name            text not null,             -- name on Spotify
  artist_name_key text,                      -- staging.name_key of the NDN artist (null = not in NDN list)
  tiktok_handle   text,                      -- raw.tiktok_accounts handle, for the 13 non-NDN artists
  match_type      text not null,
  evidence        text,                      -- e.g. the NDN song found on Spotify, or the bio link
  active          boolean not null default true,
  added_at        timestamptz not null default now(),
  note            text
);
create index if not exists spotify_artists_key on raw.spotify_artists (artist_name_key);

-- Name searches (logged-out web search, artists tab), kept to explain each match.
create table if not exists raw.spotify_search (
  query_key  text primary key,               -- artist_name_key, or 'tiktok:' || handle
  query      text not null,
  fetched_at timestamptz not null default now(),
  results    jsonb not null,                 -- [{id, name, verified}] top 10 artists
  pick       jsonb                           -- {spotify_id, match_type, evidence} or null
);

create table if not exists raw.spotify_artist_snapshot (
  spotify_id    text not null,
  snapshot_date date not null,
  fetched_at    timestamptz not null default now(),
  payload       jsonb not null,              -- artistUnion: profile {name, verified}, stats {followers,
                                             -- monthlyListeners, worldRank, topCities}, topTracks
                                             -- [{id, name, playcount}], releases {albums, singles, latest}
  primary key (spotify_id, snapshot_date)
);

create table if not exists raw.kworb_artist_songs (
  spotify_id    text not null,
  snapshot_date date not null,
  fetched_at    timestamptz not null default now(),
  found         boolean not null,            -- false = kworb has no page (404)
  kworb_updated date,                        -- "Last updated" on the page
  payload       jsonb,                       -- {totals: {streams, daily, tracks}, songs: [{track_id,
                                             -- title, streams, daily, feature}]}
  primary key (spotify_id, snapshot_date)
);

alter table raw.spotify_artists enable row level security;
alter table raw.spotify_search enable row level security;
alter table raw.spotify_artist_snapshot enable row level security;
alter table raw.kworb_artist_songs enable row level security;

------------------------------------------------------------------ staging
create or replace view staging.spotify_artist as
select a.spotify_id, a.name as spotify_name, a.artist_name_key,
       n.name as ndn_name, a.tiktok_handle, a.match_type, a.evidence, a.active
from raw.spotify_artists a
left join (select name_key, min(name) as name from staging.ndn_artist group by 1) n on n.name_key = a.artist_name_key;

create or replace view staging.spotify_artist_snapshot as
select s.spotify_id, a.artist_name_key, a.tiktok_handle, s.snapshot_date,
       s.payload->'profile'->>'name'                         as name,
       (s.payload->'profile'->>'verified')::boolean          as verified,
       (s.payload->'stats'->>'monthlyListeners')::bigint     as monthly_listeners,
       (s.payload->'stats'->>'followers')::bigint            as followers,
       nullif((s.payload->'stats'->>'worldRank')::int, 0)    as world_rank,
       round((s.payload->'stats'->>'followers')::numeric
             / nullif((s.payload->'stats'->>'monthlyListeners')::numeric, 0), 3) as followers_per_listener,
       (s.payload->'releases'->>'albums')::int               as albums,
       (s.payload->'releases'->>'singles')::int              as singles,
       s.payload->'releases'->'latest'->>'name'              as latest_release,
       (s.payload->'releases'->'latest'->>'date')::date      as latest_release_date
from raw.spotify_artist_snapshot s
left join raw.spotify_artists a using (spotify_id);

create or replace view staging.spotify_top_city as
select s.spotify_id, s.snapshot_date, c.n::int as city_rank,
       c.x->>'city' as city, c.x->>'country' as country, (c.x->>'numberOfListeners')::bigint as listeners
from raw.spotify_artist_snapshot s,
     jsonb_array_elements(coalesce(s.payload->'stats'->'topCities'->'items', '[]')) with ordinality c(x, n);

create or replace view staging.spotify_top_track as
select s.spotify_id, s.snapshot_date, t.n::int as track_rank,
       t.x->>'id' as track_id, t.x->>'name' as track, (t.x->>'playcount')::bigint as playcount
from raw.spotify_artist_snapshot s,
     jsonb_array_elements(coalesce(s.payload->'topTracks', '[]')) with ordinality t(x, n);

create or replace view staging.kworb_artist_total as
select k.spotify_id, k.snapshot_date, k.kworb_updated, k.found,
       (k.payload->'totals'->>'streams')::bigint as total_streams,
       (k.payload->'totals'->>'daily')::bigint   as daily_streams,
       (k.payload->'totals'->>'tracks')::int     as tracks
from raw.kworb_artist_songs k;

create or replace view staging.kworb_song as
select k.spotify_id, k.snapshot_date, k.kworb_updated,
       x->>'track_id' as track_id, x->>'title' as title,
       (x->>'streams')::bigint as total_streams, (x->>'daily')::bigint as daily_streams,
       coalesce((x->>'feature')::boolean, false) as as_feature
from raw.kworb_artist_songs k, jsonb_array_elements(coalesce(k.payload->'songs', '[]')) x
where k.found;

-- 015b: NDN name -> Spotify artist, including other spellings of the same artist
-- ("Janine Teñoso" / "Janine Tenoso"). An alias = a raw.spotify_search row whose pick has
-- match_type 'alias' and points to an artist already in raw.spotify_artists. Join NDN data on this.
create or replace view staging.spotify_name_map as
select a.artist_name_key as name_key, a.spotify_id, a.match_type
from raw.spotify_artists a where a.active and a.artist_name_key is not null
union
select s.query_key, a.spotify_id, 'alias'
from raw.spotify_search s join raw.spotify_artists a on a.spotify_id = s.pick->>'spotify_id' and a.active
where s.pick->>'match_type' = 'alias' and s.query_key not like 'tiktok:%';
