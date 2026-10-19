-- 013: data set "trends + artist catalogs" (Q16). Plan: TikTok_NDN.md.
--   A. What is trending in the Philippines, one snapshot a week:
--      - TikTok Creative Center top hashtags, PH, last 7 days: overall + per industry
--        (logged-out visitors get the top 3 of each list; we never log in).
--      - Spotify Philippines weekly chart (top 200), from kworb.net. Creative Center's
--        songs list is gone (all song/music URLs redirect to hashtags, checked 2026-10-19),
--        so kworb is the trending-songs source.
--   B. Every artist NDN has posted on YouTube, matched to Deezer, with their full catalog.
-- Loaded untouched by the Edge Function music-weekly; all cleaning happens in the views below.

------------------------------------------------------------------ raw (Extract + Load)
create table if not exists raw.music_runs (
  run_id      bigserial primary key,
  part        text not null,                 -- 'trends' or 'deezer'
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  run_by      text,                          -- pg_cron / manual
  status      text not null default 'running',
  detail      jsonb
);

-- One row per chart per week. TikTok: JSON reply in payload. kworb: the HTML page in body.
create table if not exists raw.trend_responses (
  source        text not null,               -- 'tiktok_cc' or 'kworb'
  chart         text not null,               -- e.g. 'hashtag_7d_all', 'hashtag_7d_23', 'spotify_ph_weekly'
  snapshot_date date not null,               -- PH date of the run
  fetched_at    timestamptz not null default now(),
  url           text,
  request       jsonb,
  payload       jsonb,
  body          text,
  primary key (source, chart, snapshot_date)
);

-- Deezer artist search, one row per search text (normalized), result list untouched.
create table if not exists raw.deezer_search (
  query_key  text primary key,               -- lower, letters/digits only
  query      text not null,
  fetched_at timestamptz not null default now(),
  payload    jsonb not null
);

-- Every release (album / EP / single) of a matched artist; refetched weekly for new releases.
create table if not exists raw.deezer_artist_albums (
  deezer_artist_id bigint primary key,
  fetched_at       timestamptz not null default now(),
  payload          jsonb not null            -- {"data": [...all pages...]}
);

-- Track list of one release; fetched once (releases don't change).
create table if not exists raw.deezer_album_tracks (
  album_id   bigint primary key,
  fetched_at timestamptz not null default now(),
  payload    jsonb not null
);

-- Vic's manual fixes for wrong or missing matches (empty to start).
--   deezer_artist_id = the right Deezer artist (find it at deezer.com/artist/<id>), or
--   null + note 'not on deezer' to stop matching that name.
create table if not exists raw.music_artist_override (
  name_key         text primary key,         -- same normalization as query_key
  deezer_artist_id bigint,
  note             text
);

alter table raw.music_runs enable row level security;
alter table raw.trend_responses enable row level security;
alter table raw.deezer_search enable row level security;
alter table raw.deezer_artist_albums enable row level security;
alter table raw.deezer_album_tracks enable row level security;
alter table raw.music_artist_override enable row level security;

create or replace function staging.name_key(t text) returns text
language sql immutable as $$ select lower(regexp_replace(coalesce(t, ''), '[^[:alnum:]]', '', 'g')) $$;

-- Song title for matching: drop "(feat. ...)", "(Live ...)", "- Remastered" etc., then name_key.
create or replace function staging.title_key(t text) returns text
language sql immutable as $$
  select staging.name_key(regexp_replace(regexp_replace(coalesce(t, ''),
           '\s*[\(\[][^\)\]]*[\)\]]', '', 'g'), '\s+-\s+.*$', ''))
$$;

------------------------------------------------------------------ staging: NDN artists
-- Every artist credit on NDN's YouTube titles, plus its parts when it is a collaboration.
-- Parts are only used when the full credit has no exact Deezer match (so "Ben & Ben" stays whole).
create or replace view staging.ndn_artist_credit as
with credits as (
  select btrim(regexp_replace(artist, '^[-—–\s]+', '')) as credit, published_date_ph
  from mart.dim_video
  where platform = 'YouTube' and artist is not null
)
select staging.name_key(c.credit) as credit_key,
       min(c.credit) as credit,
       p.part_no,
       btrim(p.part) as name,
       staging.name_key(p.part) as name_key,
       count(*) as youtube_videos,
       min(c.published_date_ph) as first_posted,
       max(c.published_date_ph) as last_posted
from credits c
cross join lateral (
  select 0 as part_no, c.credit as part
  union all
  select n::int, s
  from regexp_split_to_table(c.credit, '\s*(,|\s&\s|\sft\.?\s|\sfeat\.?\s|\sand\s|\sx\s|\sw/\s)\s*', 'i')
       with ordinality as t(s, n)
  where c.credit ~* '(,|\s&\s|\sft\.?\s|\sfeat\.?\s|\sand\s|\sx\s|\sw/\s)'
) p
where staging.name_key(p.part) <> ''
group by 1, 3, 4, 5;

------------------------------------------------------------------ staging: Deezer
-- Best Deezer artist for each search: exact name first, then a partial name, most fans first.
create or replace view staging.deezer_artist_match as
with cand as (
  select s.query_key, s.query, s.fetched_at,
         (a->>'id')::bigint as deezer_artist_id,
         a->>'name' as deezer_name,
         (a->>'nb_fan')::int as fans,
         (a->>'nb_album')::int as releases,
         ord as search_rank,
         case when staging.name_key(a->>'name') = s.query_key then 'exact'
              when length(s.query_key) >= 4 and (staging.name_key(a->>'name') like '%' || s.query_key || '%'
                    or s.query_key like '%' || staging.name_key(a->>'name') || '%') then 'partial'
         end as match_type
  from raw.deezer_search s,
       jsonb_array_elements(s.payload->'data') with ordinality as x(a, ord)
),
ranked as (
  select c.*,
         count(*) filter (where match_type = 'exact') over (partition by query_key) as n_exact,
         row_number() over (partition by query_key
                            order by (match_type = 'exact') desc, fans desc nulls last, search_rank) as rn
  from cand c where match_type is not null
)
select q.query_key, q.query,
       coalesce(o.deezer_artist_id, r.deezer_artist_id) as deezer_artist_id,
       case when o.name_key is not null then 'manual'
            when r.match_type = 'exact' and r.n_exact > 1 then 'exact_but_shared_name'
            else coalesce(r.match_type, 'none') end as match_type,
       r.deezer_name, r.fans, r.releases, o.note as override_note
from raw.deezer_search q
left join ranked r on r.query_key = q.query_key and r.rn = 1
left join raw.music_artist_override o on o.name_key = q.query_key;

-- NDN credit -> Deezer artist(s). Full credit if it matched exactly (or manually), else its parts.
create or replace view staging.ndn_artist as
-- Only exact and manual matches get a Deezer id; partial ones were mostly wrong (Psyka -> Psy),
-- so they stay visible in deezer_artist_match for Vic to confirm via raw.music_artist_override.
with m as (
  select c.*,
         case when d.match_type in ('exact', 'exact_but_shared_name', 'manual') then d.deezer_artist_id end
           as deezer_artist_id,
         d.match_type, d.deezer_name, d.fans
  from staging.ndn_artist_credit c
  left join staging.deezer_artist_match d on d.query_key = c.name_key
),
full_ok as (
  select credit_key from m
  where part_no = 0 and match_type in ('exact', 'exact_but_shared_name', 'manual') and deezer_artist_id is not null
)
select m.credit_key, m.credit, m.name, m.name_key, m.part_no,
       m.youtube_videos, m.first_posted, m.last_posted,
       m.deezer_artist_id, m.deezer_name, m.fans, coalesce(m.match_type, 'not_searched') as match_type
from m
where (m.part_no = 0 and (m.credit_key in (select credit_key from full_ok)
                          or not exists (select 1 from m m2 where m2.credit_key = m.credit_key and m2.part_no > 0)))
   or (m.part_no > 0 and m.credit_key not in (select credit_key from full_ok));

create or replace view staging.music_release as
select a.deezer_artist_id,
       (r->>'id')::bigint as album_id,
       r->>'title' as title,
       r->>'record_type' as record_type,          -- album / ep / single / compile
       nullif(r->>'release_date', '0000-00-00')::date as release_date,
       (r->>'nb_tracks')::int as n_tracks,
       (r->>'fans')::int as fans,
       r->>'link' as url
from raw.deezer_artist_albums a, jsonb_array_elements(a.payload->'data') r;

create or replace view staging.music_track as
select t.album_id,
       (x->>'id')::bigint as track_id,
       x->>'title' as title,
       x->>'title_short' as title_short,
       staging.title_key(x->>'title_short') as title_key,
       (x->>'track_position')::int as track_no,
       (x->>'duration')::int as duration_sec,
       x->>'isrc' as isrc,
       (x->'artist'->>'id')::bigint as track_artist_id,
       x->'artist'->>'name' as track_artist
from raw.deezer_album_tracks t, jsonb_array_elements(t.payload->'data') x;

-- One row per artist and song (a song on a single and later on an album counts once, earliest date).
-- status: posted = NDN has a video of it (any platform); before_last_visit = out before NDN's latest
-- visit with that artist but never posted (could have been in the set); after_last_visit = released later.
-- A "visit" = a run of YouTube uploads with no gap over 60 days (stand-in for the show date).
create or replace view staging.music_catalog_status as
with art as (
  select distinct deezer_artist_id, credit_key from staging.ndn_artist where deezer_artist_id is not null
),
uploads as (
  select a.deezer_artist_id, v.published_date_ph as d
  from art a join mart.dim_video v
    on v.platform = 'YouTube' and staging.name_key(btrim(regexp_replace(v.artist, '^[-—–\s]+', ''))) = a.credit_key
),
visits as (
  select deezer_artist_id, d,
         sum(case when gap is null or gap > 60 then 1 else 0 end)
           over (partition by deezer_artist_id order by d) as visit_no
  from (select deezer_artist_id, d, d - lag(d) over (partition by deezer_artist_id order by d) as gap
        from (select distinct deezer_artist_id, d from uploads) u0) u
),
visit_info as (
  select deezer_artist_id, max(visit_no)::int as visits,
         max(d) filter (where visit_no = (select max(v2.visit_no) from visits v2 where v2.deezer_artist_id = v.deezer_artist_id)) as last_visit_end,
         min(d) filter (where visit_no = (select max(v2.visit_no) from visits v2 where v2.deezer_artist_id = v.deezer_artist_id)) as last_visit_start,
         min(d) as first_upload
  from visits v group by deezer_artist_id
),
songs as (
  select r.deezer_artist_id, t.title_key,
         min(t.title_short) as song,
         min(r.release_date) as first_release,
         (array_agg(r.record_type order by r.release_date))[1] as first_release_type,
         count(distinct r.album_id) as on_releases
  from staging.music_release r join staging.music_track t using (album_id)
  where t.title_key <> ''
  group by 1, 2
),
posted as (
  select a.deezer_artist_id, staging.title_key(v.song) as title_key,
         string_agg(distinct v.platform, ', ') as platforms, min(v.published_date_ph) as first_posted,
         count(*) as videos
  from art a join mart.dim_video v
    on staging.name_key(btrim(regexp_replace(v.artist, '^[-—–\s]+', ''))) = a.credit_key
  where v.song is not null
  group by 1, 2
)
select s.deezer_artist_id, m.deezer_name as artist, s.song, s.title_key,
       s.first_release, s.first_release_type, s.on_releases,
       vi.visits, vi.first_upload, vi.last_visit_start, vi.last_visit_end,
       p.platforms as posted_on, p.first_posted, coalesce(p.videos, 0) as posted_videos,
       case when p.title_key is not null then 'posted'
            when s.first_release <= vi.last_visit_start then 'before_last_visit'
            else 'after_last_visit' end as status
from songs s
join (select distinct on (deezer_artist_id) deezer_artist_id, deezer_name from staging.ndn_artist
      where deezer_artist_id is not null order by deezer_artist_id, fans desc nulls last) m using (deezer_artist_id)
left join visit_info vi using (deezer_artist_id)
left join posted p using (deezer_artist_id, title_key);

------------------------------------------------------------------ staging: trends
-- Industry names: 23 and 25 seen as labels on the page; the rest follow the old Creative Center list (inferred).
create or replace view staging.trend_tiktok_hashtag as
select r.snapshot_date,
       case when r.chart = 'hashtag_7d_all' then null else split_part(r.chart, '_', 3)::bigint end as industry_id,
       case split_part(r.chart, '_', 3)
         when 'all' then 'All' when '10' then 'Education' when '11' then 'Vehicle & Transportation'
         when '12' then 'Baby, Kids & Maternity' when '13' then 'Financial Services'
         when '14' then 'Beauty & Personal Care' when '15' then 'Tech & Electronics'
         when '16' then 'Appliances' when '17' then 'Travel' when '18' then 'Household Products'
         when '19' then 'Pets' when '20' then 'Apps' when '21' then 'Home Improvement'
         when '22' then 'Apparel & Accessories' when '23' then 'News & Entertainment'
         when '24' then 'Business Services' when '25' then 'Games' when '27' then 'Food & Beverage'
         when '28' then 'Sports & Outdoor' when '29' then 'Health' end as industry,
       (h->>'rankIndex')::int as rank,
       h->>'hashtagName' as hashtag,
       (h->>'publishCnt')::bigint as posts,
       (h->>'vv')::bigint as views,
       h->'popularityCurve' as popularity_curve
from raw.trend_responses r, jsonb_array_elements(r.payload->'items') h
where r.source = 'tiktok_cc';

-- kworb page -> one row per chart line. Artists: main artist(s) before " - ", guests after "(w/".
create or replace view staging.trend_spotify_ph as
with rows as (
  select r.snapshot_date,
         to_date(substring(r.body from 'Philippines - (\d{4}/\d{2}/\d{2})'), 'YYYY/MM/DD') as chart_date,
         split_part(tr, '</tr>', 1) as tr
  -- split, not a lazy regex: Postgres gives a whole pattern the greediness of its first quantifier
  from raw.trend_responses r, regexp_split_to_table(r.body, '<tr[ >]') tr
  where r.source = 'kworb' and r.chart = 'spotify_ph_weekly'
),
cells as (
  select snapshot_date, chart_date, tr,
         array(select substring(c from '<td[^>]*>(.*)$')
               from regexp_split_to_table(tr, '</td>') with ordinality as x(c, n)
               where c like '%<td%' order by n) as td
  from rows where tr like '%<td%'
)
select snapshot_date, chart_date,
       td[1]::int as rank,
       td[2] as change,                                    -- =, +2, -1, NEW, RE
       regexp_replace(split_part(td[3], '</a> - <a', 1), '<[^>]+>', '', 'g') as artist,
       substring(td[3] from 'track/([A-Za-z0-9]+)\.html') as spotify_track_id,
       substring(td[3] from 'track/[A-Za-z0-9]+\.html">([^<]*)</a>') as song,
       nullif(btrim(regexp_replace(substring(td[3] from '\(w/ (.*)\)'), '<[^>]+>', '', 'g')), '') as with_artists,
       array(select a[1] from regexp_matches(td[3], 'artist/([A-Za-z0-9]+)\.html', 'g') a) as spotify_artist_ids,
       td[4]::int as weeks_on_chart,
       td[5]::int as peak,
       replace(td[7], ',', '')::bigint as streams,
       nullif(replace(replace(td[8], ',', ''), '+', ''), '')::bigint as streams_change,
       replace(td[9], ',', '')::bigint as total_streams
from cells
where td[1] ~ '^\d+$';

-- Trending songs flagged when the artist (main or guest) has played for NDN.
create or replace view staging.trend_spotify_ph_ndn as
select t.*,
       exists (select 1 from staging.ndn_artist a
               where a.deezer_artist_id is not null
                 and (a.name_key = staging.name_key(t.artist)
                  or a.name_key = any (select staging.name_key(x) from regexp_split_to_table(
                       coalesce(t.artist, '') || ',' || coalesce(t.with_artists, ''), '\s*(,|&)\s*') x))) as is_ndn_artist
from staging.trend_spotify_ph t;

------------------------------------------------------------------ schedule (pg_cron, PH = UTC+8)
-- Mondays 10:00 PH: trends snapshot (kworb's weekly chart is out by Friday).
-- Mondays 10:10-11:50 PH, every 10 min: Deezer. Usually 1-2 calls do the week's work (new names,
-- releases refetched, tracks of new releases); the rest return in a second with "finished".
select cron.schedule('ndn-music-trends-weekly', '0 2 * * 1', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/music-weekly?part=trends&by=pg_cron',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);
select cron.schedule('ndn-music-deezer-weekly', '10-59/10 2-3 * * 1', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/music-weekly?part=deezer&by=pg_cron&budget=500',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'ndn_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
$$);

-- Checks:
--   select * from raw.music_runs order by run_id desc limit 5;
--   select match_type, count(*) from staging.deezer_artist_match group by 1;
