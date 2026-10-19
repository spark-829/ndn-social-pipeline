-- 014: TikTok extras (2026-10-20). Weekly, by extract_tiktok_extras.py -> Edge Function tiktok-extras.
--   1. Video page per video: sound (music id, original or not), real repost count, tagged place,
--      @mentions, TikTok's suggested search words. Fetched once, refreshed weekly while < 30 days old.
--   2. Sound pages: how many TikTok videos use each sound (Q12), one row per sound per week.
--   3. Comments (top-level) for fan requests / questions / mood, refetched when the count grows.
--   4+5. Profile snapshots of artists' own accounts and of benchmark accounts, weekly.
-- Not untouched in two places, to save space: the video page drops video/author/image links
-- (like extract_tiktok.py drops thumbnails), and comments keep only the fields listed below.

------------------------------------------------------------------ raw
create table if not exists raw.tiktok_video_page (
  video_id   text primary key,
  fetched_at timestamptz not null default now(),
  item       jsonb not null           -- itemStruct from the video page, minus video/author/imagePost/desc
);

create table if not exists raw.tiktok_sound_stats (
  music_id      text not null,
  snapshot_date date not null,
  fetched_at    timestamptz not null default now(),
  payload       jsonb not null,       -- musicInfo from the sound page (music, author, stats)
  primary key (music_id, snapshot_date)
);

create table if not exists raw.tiktok_comments (
  cid        text primary key,
  video_id   text not null,
  fetched_at timestamptz not null default now(),
  comment    jsonb not null           -- cid, text, create_time, digg_count, reply_comment_total,
                                      -- author_pin, is_author_digged, user {unique_id, nickname}
);
create index if not exists tiktok_comments_video on raw.tiktok_comments (video_id);

create table if not exists raw.tiktok_comment_fetch (
  video_id       text primary key,
  fetched_at     timestamptz not null default now(),
  count_at_fetch int,                 -- comment count in the snapshot when we fetched
  saved          int
);

-- Accounts to snapshot: artists' own TikTok accounts and benchmark accounts.
--   source 'caption_mention' = found automatically (NDN tagged them), 'manual' = added by Vic.
--   Set active = false to stop a wrong one.
create table if not exists raw.tiktok_accounts (
  handle          text primary key,   -- without @
  role            text not null check (role in ('artist', 'benchmark')),
  artist_name_key text,               -- staging.name_key of the NDN artist, for role 'artist'
  source          text not null default 'manual',
  active          boolean not null default true,
  note            text
);

create table if not exists raw.tiktok_account_snapshot (
  handle        text not null,
  snapshot_date date not null,
  fetched_at    timestamptz not null default now(),
  payload       jsonb not null,       -- webapp.user-detail userInfo (user + stats + statsV2)
  primary key (handle, snapshot_date)
);

alter table raw.tiktok_video_page enable row level security;
alter table raw.tiktok_sound_stats enable row level security;
alter table raw.tiktok_comments enable row level security;
alter table raw.tiktok_comment_fetch enable row level security;
alter table raw.tiktok_accounts enable row level security;
alter table raw.tiktok_account_snapshot enable row level security;

insert into raw.tiktok_accounts (handle, role, source, note) values
  ('wish1075official', 'benchmark', 'manual', 'Wish 107.5 (Wish Bus sessions); handle from wish1075.com')
on conflict do nothing;

------------------------------------------------------------------ staging
create or replace view staging.tiktok_video_page as
select p.video_id,
       p.fetched_at,
       p.item->'music'->>'id'                      as music_id,
       p.item->'music'->>'title'                   as sound_title,
       p.item->'music'->>'authorName'              as sound_author,
       (p.item->'music'->>'original')::boolean     as sound_is_original,
       (p.item->'statsV2'->>'repostCount')::bigint as reposts,
       p.item->'poi'->>'name'                      as place,
       p.item->>'locationCreated'                  as location_created,
       array(select jsonb_array_elements_text(coalesce(p.item->'suggestedWords', '[]'))) as suggested_words,
       (p.item->>'CategoryType')::int              as category_type,
       (p.item ? 'imagePostCount')                 as is_photo_post,
       (p.item->>'isAd')::boolean                  as is_ad
from raw.tiktok_video_page p;

-- @mentions in NDN's captions (from the page's structured text, not regex on the caption).
create or replace view staging.tiktok_mention as
select distinct p.video_id, lower(x->>'userUniqueId') as handle
from raw.tiktok_video_page p,
     jsonb_array_elements(coalesce(p.item->'contents', '[]')) c,
     jsonb_array_elements(coalesce(c->'textExtra', '[]')) x
where coalesce(x->>'userUniqueId', '') <> '' and lower(x->>'userUniqueId') <> 'ninedegreesnorth';

-- Artist account candidates: a mentioned handle that contains an NDN artist's name (4+ letters).
create or replace view staging.tiktok_artist_account_candidate as
with h as (
  select handle, count(*) as mentions from staging.tiktok_mention group by 1
)
select distinct on (h.handle) h.handle, h.mentions, a.name_key as artist_name_key, a.name as artist
from h
join (select distinct name_key, name from staging.ndn_artist where deezer_artist_id is not null and length(name_key) >= 4) a
  on staging.name_key(h.handle) like '%' || a.name_key || '%'
order by h.handle, length(a.name_key) desc;

create or replace view staging.tiktok_sound_stats as
select s.music_id, s.snapshot_date,
       s.payload->'music'->>'title'                 as sound_title,
       s.payload->'music'->>'authorName'            as sound_author,
       (s.payload->'music'->>'original')::boolean   as sound_is_original,
       (s.payload->'stats'->>'videoCount')::bigint  as videos_using_sound
from raw.tiktok_sound_stats s;

create or replace view staging.tiktok_comment as
select c.cid, c.video_id,
       c.comment->>'text'                                   as text,
       to_timestamp((c.comment->>'create_time')::bigint)    as created_at,
       (c.comment->>'digg_count')::int                      as likes,
       (c.comment->>'reply_comment_total')::int             as replies,
       c.comment->'user'->>'unique_id'                      as author_handle,
       coalesce((c.comment->>'author_pin')::boolean, false) as pinned_by_ndn,
       coalesce((c.comment->>'is_author_digged')::boolean, false) as liked_by_ndn
from raw.tiktok_comments c;

create or replace view staging.tiktok_account_snapshot_other as
select s.handle, a.role, a.artist_name_key, s.snapshot_date,
       s.payload->'user'->>'nickname'                    as name,
       (s.payload->'statsV2'->>'followerCount')::bigint  as followers,
       (s.payload->'statsV2'->>'heartCount')::bigint     as hearts,
       (s.payload->'statsV2'->>'videoCount')::int        as videos
from raw.tiktok_account_snapshot s
left join raw.tiktok_accounts a using (handle);

-- 014b: auto-found artist accounts get role 'artist' and their artist from the candidate list.
create or replace view staging.tiktok_account_snapshot_other as
select s.handle,
       coalesce(a.role, case when c.handle is not null then 'artist' end) as role,
       coalesce(a.artist_name_key, c.artist_name_key) as artist_name_key,
       s.snapshot_date,
       s.payload->'user'->>'nickname'                    as name,
       (s.payload->'statsV2'->>'followerCount')::bigint  as followers,
       (s.payload->'statsV2'->>'heartCount')::bigint     as hearts,
       (s.payload->'statsV2'->>'videoCount')::int        as videos,
       case when a.handle is not null then a.source else 'caption_mention' end as found_by
from raw.tiktok_account_snapshot s
left join raw.tiktok_accounts a using (handle)
left join staging.tiktok_artist_account_candidate c on c.handle = s.handle;
