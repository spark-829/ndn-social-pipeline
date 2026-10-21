-- 023_fan_requests.sql (2026-10-21, FAN_REQUESTS.md Part B steps 2-5)
-- Which artists fans ask NDN for, from TikTok + YouTube comments (staging.fan_comment).
--   mart.artist_alias        names to look for: Spotify name, NDN credit, TikTok handle, manual extras/stoplist
--   mart.comment_artist_hit  one row per comment x artist named in it (insert-only; kept when comment text is pruned)
--   staging.fan_request_candidate   hits on ANOTHER artist's video, or a strong request word
--   raw.comment_label        Claude's (or Vic's) label per candidate
--   mart.comment_artist_mention     counts per video x artist
-- Matching: comment split on spaces, each word reduced to staging.name_key (letters + digits), then
-- runs of 1-4 words glued together are compared to the alias key by equality. "Ben&Ben", "@benandben"
-- and "BEN & BEN" all work without a 164k x 600 regex join (that timed out), and "sica" no longer
-- matches inside "musica".

------------------------------------------------------------------ 1. names
create table if not exists mart.artist_alias (
  alias_key   text not null,                 -- staging.name_key(alias)
  spotify_id  text not null,                 -- or 'manual:<name_key>' for artists not on Spotify
  alias       text not null,
  source      text not null,                 -- spotify, ndn_credit, tiktok_handle, manual
  stop        boolean not null default false,-- common word / false match: never counts
  primary key (alias_key, spotify_id)
);
alter table mart.artist_alias enable row level security;

create or replace function mart.refresh_artist_alias() returns int language sql as $$
  with src as (
    select spotify_name as alias, spotify_id, 'spotify' as source from staging.spotify_artist where active
    union all select ndn_name, spotify_id, 'ndn_credit' from staging.spotify_artist where active and ndn_name is not null
    union all select n.name, m.spotify_id, 'ndn_credit' from staging.ndn_artist n
              join staging.spotify_name_map m on m.name_key = n.name_key
    union all select ltrim(tiktok_handle, '@'), spotify_id, 'tiktok_handle' from staging.spotify_artist
              where active and tiktok_handle is not null
  ), ins as (
    insert into mart.artist_alias (alias_key, spotify_id, alias, source)
    select distinct on (staging.name_key(alias), spotify_id) staging.name_key(alias), spotify_id, alias, source
    from src where length(staging.name_key(alias)) >= 3
    order by staging.name_key(alias), spotify_id, source desc
    on conflict do nothing returning 1
  ) select count(*)::int from ins;
$$;

-- a key that points to 2+ artists is ambiguous: it never counts
create or replace view mart.artist_alias_usable as
select alias_key, min(spotify_id) as spotify_id, min(alias) as alias
from mart.artist_alias
group by alias_key
having not bool_or(stop) and count(distinct spotify_id) = 1;

------------------------------------------------------------------ 2. name hits
create table if not exists mart.comment_artist_hit (
  platform    text not null,
  comment_id  text not null,
  spotify_id  text not null,
  video_id    text not null,
  likes       bigint,
  own_video   boolean not null,              -- the artist is credited on this video (praise, not a request)
  primary key (platform, comment_id, spotify_id)
);
alter table mart.comment_artist_hit enable row level security;

create table if not exists mart.comment_hit_scan (   -- which comments were already scanned
  platform text not null, comment_id text not null, scanned_at timestamptz not null default now(),
  primary key (platform, comment_id)
);
alter table mart.comment_hit_scan enable row level security;

-- artists credited on each video (TikTok + YouTube), via the parsed artist and spotify_name_map
create or replace view staging.video_artist as
select distinct v.platform, v.video_id, m.spotify_id
from mart.dim_video v
cross join lateral regexp_split_to_table(v.artist, '\s*(?:,|&|\mx\M|\mft\.?|\mfeat\.?|\mwith\M|\mand\M)\s*', 'i') as part
join staging.spotify_name_map m on m.name_key = staging.name_key(part)
where v.platform in ('TikTok', 'YouTube') and v.artist is not null
union
select v.platform, v.video_id, m.spotify_id
from mart.dim_video v
join staging.spotify_name_map m on m.name_key = staging.name_key(v.artist)
where v.platform in ('TikTok', 'YouTube');

-- scan up to n unscanned comments; returns hits added. Words that reduce to '' (emoji, "&") are
-- dropped first, so "Ben & Ben" glues to 'benben'.
create or replace function mart.scan_comment_hits(n int default 20000) returns int
language plpgsql set statement_timeout = '110s' as $$
declare added int;
begin
  create temp table batch on commit drop as
  select c.platform, c.comment_id, c.video_id, c.likes, c.text
  from staging.fan_comment c
  where not exists (select 1 from mart.comment_hit_scan s where s.platform = c.platform and s.comment_id = c.comment_id)
  limit n;
  create temp table va on commit drop as select * from staging.video_artist;   -- dim_video is heavy: read once

  insert into mart.comment_artist_hit (platform, comment_id, spotify_id, video_id, likes, own_video)
  with w as (
    select b.platform, b.comment_id, t.pos, staging.name_key(t.word) as k
    from batch b cross join lateral regexp_split_to_table(coalesce(b.text, ''), '\s+') with ordinality as t(word, pos)
  ), g as (
    select platform, comment_id, k as k1,
           k || lead(k, 1) over c as k2,
           k || lead(k, 1) over c || lead(k, 2) over c as k3,
           k || lead(k, 1) over c || lead(k, 2) over c || lead(k, 3) over c as k4
    from w where k <> ''
    window c as (partition by platform, comment_id order by pos)
  ), h as (
    select distinct g.platform, g.comment_id, a.spotify_id
    from g cross join lateral unnest(array[k1, k2, k3, k4]) as key
    join mart.artist_alias_usable a on a.alias_key = key
  )
  select h.platform, h.comment_id, h.spotify_id, b.video_id, b.likes,
         exists (select 1 from va
                 where va.platform = b.platform and va.video_id = b.video_id and va.spotify_id = h.spotify_id)
  from h join batch b on b.platform = h.platform and b.comment_id = h.comment_id
  on conflict do nothing;
  get diagnostics added = row_count;

  insert into mart.comment_hit_scan (platform, comment_id) select platform, comment_id from batch on conflict do nothing;
  return added;
end $$;

------------------------------------------------------------------ 3. stoplist (checked 2026-10-21 on the top 45 names
-- by hits outside the artist's own videos; samples: "Because" alone, "not a fan of this band", "much love",
-- "the moon and the sun", "can't deny", "since day one", "Justin Bieber", "@Nicole Maliksi").
-- "janine" alone = Janine (Teñoso) or Janine Berdin: ambiguous, full names still count.
update mart.artist_alias set stop = true
where alias_key in ('because', 'thisband', 'muchlove', 'thesun', 'deny', 'denȳ', 'wegot', 'dayone', 'justin', 'nicole', 'janine');

-- Hits found before a name was stopped stay in the table; this view hides them. Exact while every stopped
-- name is that artist's only name (true 2026-10-21); otherwise rescan.
create or replace view mart.comment_artist_hit_usable as
select h.* from mart.comment_artist_hit h
where h.spotify_id in (select spotify_id from mart.artist_alias_usable);

------------------------------------------------------------------ 4. candidates + labels
-- request words, checked 2026-10-21 on the word-only candidates. 'strong' counts alone; 'weak' only next to
-- an artist name ("when", "bumalik", "kailan" alone are mostly lyrics; "sana" alone is noise).
create or replace function staging.request_word(t text) returns text language sql immutable as $$
  select case
    when coalesce(t, '') ~* '\m(next|invite|guest|sunod|isunod|upload|full ?version|full vid|request|collab)\M' then 'strong'
    when coalesce(t, '') ~* '\m(pls|plz|please|balik|bumalik|kailan|spotify|sana|naman)\M' then 'weak'
  end
$$;
drop function if exists staging.has_request_word(text) cascade;

create table if not exists raw.comment_label (
  platform    text not null,
  comment_id  text not null,
  spotify_id  text not null default '',      -- artist asked for; '' = none named. A collab request = 2 rows
  label       text not null check (label in ('artist_request', 'song_request', 'collab_request', 'upload_request',
                                             'mention_no_ask', 'noise')),
  asked_name  text,                          -- name as written when the artist isn't in mart.artist_alias yet (step 7)
  labeled_by  text not null,                 -- claude, vic, rule
  labeled_at  timestamptz not null default now(),
  primary key (platform, comment_id, spotify_id)
);
alter table raw.comment_label enable row level security;
alter table raw.comment_label add column if not exists asked_name text;

-- what needs a label. read = Claude reads it; rule = names another artist with no request word, labeled
-- mention_no_ask by rule (a sample is read to check the rule, FAN_REQUESTS.md step 6)
create or replace view staging.fan_request_candidate as
with c as (
  select c.platform, c.comment_id, c.video_id, c.text, c.created_at, c.likes, c.author_key,
         coalesce((select array_agg(h.spotify_id order by h.spotify_id) from mart.comment_artist_hit_usable h
                   where h.platform = c.platform and h.comment_id = c.comment_id and not h.own_video), '{}') as other_artists,
         staging.request_word(c.text) as request_word
  from staging.fan_comment c
)
select c.*,
       case when cardinality(other_artists) > 0 and request_word is null then 'rule' else 'read' end as how,
       exists (select 1 from raw.comment_label l where l.platform = c.platform and l.comment_id = c.comment_id) as labeled
from c
where (cardinality(other_artists) > 0) or request_word = 'strong';

------------------------------------------------------------------ 5. counts per video x artist (survive pruning of text)
create or replace view mart.comment_artist_mention as
select platform, video_id, spotify_id, own_video, count(*) as comments, coalesce(sum(likes), 0) as likes
from mart.comment_artist_hit_usable
group by platform, video_id, spotify_id, own_video;

------------------------------------------------------------------ 6. outputs (FAN_REQUESTS.md step 3)
-- Per artist, last 12 months. spotify_id 'ask:<key>' = asked for but not in mart.artist_alias yet (Vic reviews).
-- invite_* = artist + collab requests (bring them to Cozy Cove); more_* = song + upload requests (more of an
-- artist who already played). fans = distinct commenters, so one superfan can't swamp it.
create or replace view mart.fan_demand_artist as
with base as (
  select c.platform, c.author_key, c.created_at, l.spotify_id, l.label, l.asked_name
  from raw.comment_label l
  join staging.fan_comment c using (platform, comment_id)
  where l.label in ('artist_request', 'collab_request', 'song_request', 'upload_request')
    and l.spotify_id <> '' and c.created_at > now() - interval '12 months'
), totals as (
  select platform, count(*) as comments from staging.fan_comment
  where created_at > now() - interval '12 months' group by platform
), names as (
  select spotify_id, min(alias) as artist from mart.artist_alias_usable group by spotify_id
), played as (
  select va.spotify_id, max(v.published_at)::date as last_ndn_post
  from staging.video_artist va join mart.dim_video v using (platform, video_id) group by va.spotify_id
)
select b.spotify_id,
       coalesce(n.artist, min(b.asked_name)) as artist,
       b.spotify_id like 'ask:%' as not_in_list,
       count(distinct b.author_key) as fans,
       count(distinct b.author_key) filter (where b.label in ('artist_request', 'collab_request')) as invite_fans,
       count(distinct b.author_key) filter (where b.label in ('song_request', 'upload_request')) as more_fans,
       count(*) filter (where b.platform = 'YouTube') as youtube_asks,
       count(*) filter (where b.platform = 'TikTok') as tiktok_asks,
       round(1000.0 * count(distinct b.author_key) / (select sum(comments) from totals), 3) as fans_per_1000_comments,
       round(1000.0 * count(*) filter (where b.platform = 'YouTube') / (select comments from totals where platform = 'YouTube'), 3) as youtube_per_1000,
       round(1000.0 * count(*) filter (where b.platform = 'TikTok') / nullif((select comments from totals where platform = 'TikTok'), 0), 3) as tiktok_per_1000,
       max(b.created_at)::date as latest_ask,
       p.last_ndn_post,
       p.last_ndn_post + interval '10 months' > now() as cooling_down      -- INVITE_SCORE.md cooldown rule
from base b
left join names n on n.spotify_id = b.spotify_id
left join played p on p.spotify_id = b.spotify_id
group by b.spotify_id, n.artist, p.last_ndn_post;

-- Sessions fans want posted (or put on Spotify): per artist, with the most-liked ask as an example.
create or replace view mart.fan_upload_request as
select l.spotify_id,
       coalesce((select min(alias) from mart.artist_alias_usable a where a.spotify_id = l.spotify_id), min(l.asked_name)) as artist,
       count(distinct c.author_key) as fans,
       count(*) as asks,
       count(*) filter (where c.text ~* 'spotify|apple music|streaming|music platform') as asks_for_streaming,
       max(c.created_at)::date as latest_ask,
       (array_agg(left(c.text, 200) order by c.likes desc nulls last))[1] as top_ask
from raw.comment_label l
join staging.fan_comment c using (platform, comment_id)
where l.label = 'upload_request' and l.spotify_id <> ''
group by l.spotify_id;

-- request words v2 (2026-10-21 rule check: 6 of 100 rule-labeled comments were missed requests, e.g.
-- "pleassee", "sundan mo ng ...", "when kaya makapag perform"). "perform" and "sundan" alone were 413 new
-- word-only hits, nearly all praise or lyrics, so they only count next to a name (weak).
create or replace function staging.request_word(t text) returns text language sql immutable as $$
  select case
    when coalesce(t, '') ~* '\m(next|invite|guest|sunod|isunod|upload|full ?version|full vid|request|collab)\M' then 'strong'
    when coalesce(t, '') ~* '\m(sundan|perform|pl+e*a*s+e*|plz+|pls+|plith|balik|bumalik|kailan|kelan|spotify|sana|naman|when kaya)\M' then 'weak'
  end
$$;

------------------------------------------------------------------ 7. weekly upkeep
-- Tue 12:00 PH, after TikTok comments (Mon 10:30) and youtube-comments (Tue 11:30-11:40): scan new
-- comments, label the "names another artist, no request word" ones by rule. The rest (how = 'read',
-- ~100 a week) waits for Claude in the 15:00 PH routine (Tuesdays).
create or replace function mart.weekly_fan_requests() returns jsonb language plpgsql set statement_timeout = '115s' as $$
declare hits int; ruled int;
begin
  hits := mart.scan_comment_hits(50000);
  insert into raw.comment_label (platform, comment_id, spotify_id, label, labeled_by)
  select c.platform, c.comment_id, a, 'mention_no_ask', 'rule'
  from staging.fan_request_candidate c cross join unnest(c.other_artists) a
  where c.how = 'rule' and not c.labeled
  on conflict do nothing;
  get diagnostics ruled = row_count;
  return jsonb_build_object('hits', hits, 'rule_labels', ruled,
    'to_read', (select count(*) from staging.fan_request_candidate where how = 'read' and not labeled));
end $$;

select cron.schedule('ndn-fan-requests-weekly', '0 4 * * 2', $c$select mart.weekly_fan_requests()$c$);
