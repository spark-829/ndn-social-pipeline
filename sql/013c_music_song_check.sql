-- 013c: confirm each Deezer artist with a song NDN actually posted (added 2026-10-19).
-- Why: common names ("DEMI", "Lily") have several Deezer artists, and "most fans" picked the wrong
-- one. A plain Deezer track search "<artist> <song>" returns the right artist id when the song is
-- on Deezer. (Deezer's artist:"" track:"" filters returned nothing in testing.)
-- Caveat: Deezer merges some same-name artists into one profile (e.g. Kaia, Carlo, Penelope), so
-- a confirmed profile can still list other people's releases.

create table if not exists raw.deezer_track_search (
  name_key   text primary key,               -- staging.name_key of the NDN name
  query      text not null,                  -- "<name> <song>"
  fetched_at timestamptz not null default now(),
  payload    jsonb not null
);
alter table raw.deezer_track_search enable row level security;

-- One posted song per NDN name to search with (most viewed YouTube video of a credit with that name).
create or replace view staging.ndn_artist_probe as
select distinct on (c.name_key) c.name_key, c.name, v.song
from staging.ndn_artist_credit c
join mart.dim_video v
  on v.platform = 'YouTube' and v.song is not null
 and staging.name_key(btrim(regexp_replace(v.artist, '^[-—–\s]+', ''))) = c.credit_key
where staging.title_key(v.song) <> ''
order by c.name_key, v.latest_views desc nulls last;

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
),
-- Song check: a result whose title is the posted song and whose artist name is close to the NDN name.
confirmed as (
  select distinct on (ts.name_key) ts.name_key,
         (t->'artist'->>'id')::bigint as deezer_artist_id, t->'artist'->>'name' as deezer_name
  from raw.deezer_track_search ts
  join staging.ndn_artist_probe p using (name_key)
  cross join lateral jsonb_array_elements(ts.payload->'data') with ordinality as x(t, ord)
  where staging.title_key(t->>'title_short') = staging.title_key(p.song)
    and (staging.name_key(t->'artist'->>'name') = ts.name_key
         -- close-name rule only for single names: "Dionela ft. Loonie" must not become just Dionela
         or (length(ts.name_key) >= 4
             and p.name !~* '(,|\s&\s|\sft\.?\s|\sfeat\.?\s|\sand\s|\sx\s|\sw/\s)'
             and (staging.name_key(t->'artist'->>'name') like '%' || ts.name_key || '%'
                                           or ts.name_key like '%' || staging.name_key(t->'artist'->>'name') || '%')))
  order by ts.name_key, (staging.name_key(t->'artist'->>'name') = ts.name_key) desc, ord
)
select q.query_key, q.query,
       coalesce(o.deezer_artist_id, c.deezer_artist_id, r.deezer_artist_id) as deezer_artist_id,
       case when o.name_key is not null then 'manual'
            when c.deezer_artist_id is not null then 'confirmed_by_song'
            when r.match_type = 'exact' and r.n_exact > 1 then 'exact_but_shared_name'
            else coalesce(r.match_type, 'none') end as match_type,
       coalesce(c.deezer_name, r.deezer_name) as deezer_name,
       case when c.deezer_artist_id is null or c.deezer_artist_id = r.deezer_artist_id then r.fans end as fans,
       r.releases, o.note as override_note,
       r.deezer_artist_id as name_search_pick
from raw.deezer_search q
left join ranked r on r.query_key = q.query_key and r.rn = 1
left join confirmed c on c.name_key = q.query_key
left join raw.music_artist_override o on o.name_key = q.query_key;

create or replace view staging.ndn_artist as
with m as (
  select c.*,
         case when d.match_type in ('exact', 'exact_but_shared_name', 'manual', 'confirmed_by_song')
              then d.deezer_artist_id end as deezer_artist_id,
         d.match_type, d.deezer_name, d.fans
  from staging.ndn_artist_credit c
  left join staging.deezer_artist_match d on d.query_key = c.name_key
),
full_ok as (
  select credit_key from m
  where part_no = 0 and deezer_artist_id is not null
)
select m.credit_key, m.credit, m.name, m.name_key, m.part_no,
       m.youtube_videos, m.first_posted, m.last_posted,
       m.deezer_artist_id, m.deezer_name, m.fans, coalesce(m.match_type, 'not_searched') as match_type
from m
where (m.part_no = 0 and (m.credit_key in (select credit_key from full_ok)
                          or not exists (select 1 from m m2 where m2.credit_key = m.credit_key and m2.part_no > 0)))
   or (m.part_no > 0 and m.credit_key not in (select credit_key from full_ok));
