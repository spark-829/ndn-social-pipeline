-- 017_instagram_views_parse.sql (2026-10-21, INSTAGRAM_QUESTIONS.md gap list)
-- 1. Instagram views, reposts and Facebook-inclusive totals as columns. The Edge Function
--    instagram-snapshot asks for view_count, reposts_count, total_like_count, total_comments_count
--    from 2026-10-21; older snapshots have nulls.
-- 2. Title parser v3: Instagram captions "<Song> by <Artist> premieres TONIGHT ..." and
--    "<Song> by <Artist> is now streaming ..."; patterns read the first line only, so later
--    caption lines no longer leak into song/artist.
-- 3. staging.instagram_post_latest: one row per post with caption type and hashtag count.

------------------------------------------------------------------ 1. staging columns (appended at the end)
create or replace view staging.instagram_post_snapshot as
select distinct on (r.snapshot_date, e->>'id')
       r.snapshot_date,
       e->>'id'                                   as post_id,
       e->>'caption'                              as caption,
       e->>'permalink'                            as url,
       (e->>'timestamp')::timestamptz             as published_at,
       e->>'media_type'                           as media_type,        -- IMAGE, VIDEO, CAROUSEL_ALBUM
       e->>'media_product_type'                   as product_type,      -- FEED, REELS
       (e->>'like_count')::bigint                 as likes,             -- null = likes hidden by NDN
       (e->>'comments_count')::bigint             as comments,
       (e->>'view_count')::bigint                 as views,             -- Reels only; incl. paid + crossposted Facebook views
       (e->>'reposts_count')::bigint              as reposts,           -- Repost button exists since 2025-08-06
       (e->>'total_like_count')::bigint           as total_likes,       -- Instagram + crossposted Facebook
       (e->>'total_comments_count')::bigint       as total_comments
from raw.instagram_responses r,
     jsonb_array_elements(r.payload->'business_discovery'->'media'->'data') e
order by r.snapshot_date, e->>'id';

------------------------------------------------------------------ 2. title parser v3
create or replace function mart.parse_title(t text,
    out song text, out session text, out artist text, out series text)
language plpgsql immutable set search_path = '' as $$
declare
  m   text[];
  t2  text := btrim(coalesce(t, ''));
  br  text;
  pre text;
  ln  text;
  lns text[];
  pass int;
  i   int;
  kw  constant text := '\s+(premieres|is now streaming|now streaming|is now out|is out now|out now|is now available|is streaming|streams? now)\M';
  strong constant text := '(performs?|performing|performance of)\s+[''‘"“]|\([^()]*\)|\[[^]]+\]\s*$|\sby\s[^,]+,\s*(live\s+)?(at|in)\s';
begin
  -- v3: captions run over several lines. Use the first line that looks like a song line
  -- (pass 1: performs / "by <Artist>, Live at" / "by <Artist> premieres" / brackets;
  --  pass 2: "Song - Artist", skipping numbered and "Label: value" lines), else line 1.
  lns := regexp_split_to_array(t2, '\n');
  t2 := null;
  for pass in 1..2 loop
    for i in 1..coalesce(array_length(lns, 1), 0) loop
      ln := btrim(regexp_replace(lns[i], '^\s*(watch now|watch here|stream now|out now|new)\s*[:!-]\s*', '', 'i'));
      if (pass = 1 and (ln ~* strong or ln ~* ('\sby\s.*' || kw)))
         or (pass = 2 and ln ~ '\S\s*[-–]\s+\S' and ln !~ '^\s*\d' and ln !~ ':') then
        t2 := ln;
        -- "Artist performs 'Song'" with the venue on the next line
        if t2 ~* 'perform\w*\s+[''‘"“][^''’"”]+[''’"”]\s*$' and i < array_length(lns, 1) then
          t2 := t2 || ' ' || btrim(lns[i + 1]);
        end if;
        exit;
      end if;
    end loop;
    exit when t2 is not null;
  end loop;
  t2 := coalesce(t2, btrim(lns[1]));
  br := (regexp_match(t2, '\[([^]]+)\]\s*$'))[1];
  if br is not null then
    t2 := btrim(regexp_replace(t2, '\s*\[[^]]+\]\s*$', ''));
  end if;

  m := regexp_match(t2, '^(?:watch\s+)?([^''‘’"“”]*[^''‘’"“”\s])\s*(?:performs?|performing|[''’]s (?:full )?performance of)\s+[''‘"“]([^''’"”]+)[''’"”]\s+((?:live\s+)?(?:(?:at|in)\s+)?[^.#\n]+)', 'i');
  if m is not null then
    artist := m[1]; song := m[2]; session := btrim(m[3]);
  elsif t2 ~* '^[^,]*\S\s+by\s+[^,]+,\s*(live\s+)?(at|in)\s' then
    m := regexp_match(t2, '^([^,]*[^,\s])\s+by\s+([^,]+),\s*((?:live\s+)?(?:at|in)\s+[^.#\n]+)', 'i');
    song := m[1]; artist := m[2]; session := btrim(m[3]);
  elsif t2 !~ '\(' and t2 ~* ('\sby\s.*' || kw) then
    -- v3: "<Song> by <Artist> premieres TONIGHT at 7PM ..." / "... is now streaming ..." (Instagram)
    pre := regexp_replace(t2, kw || '.*$', '', 'i');
    m := regexp_match(pre, '^(.*\S)\s+by\s+(\S.*)$', 'i');
    if m is not null then song := m[1]; artist := m[2]; end if;
  else
    m := regexp_match(t2, '^(.*\S)\s*\(([^()]*)\)\s*(?:(?:-|–|by)\s*)?(.+)$', 'i');
    if m is not null then
      song := m[1]; session := m[2]; artist := m[3];
    else
      m := regexp_match(t2, '^([^\n]*[^\s\n])\s*[-–]\s+([^\n]+)$');
      if m is not null then song := m[1]; artist := m[2]; end if;
    end if;
  end if;
  session := coalesce(session, br);

  -- captions continue after the artist: cut at the first sentence ending, hashtag or line break
  artist := regexp_replace(artist, '\s+(is now|is out|now streaming|out now|out on|premieres|streaming|available|drops|watch|full)\M.*$', '', 'i');
  artist := regexp_replace(artist, '\s*[!#\n].*$', '');
  artist := nullif(btrim(regexp_replace(artist, '[\s.,;:–-]+$', '')), '');
  song   := regexp_replace(song, '^[^[:alnum:]''‘"“(]+', '');          -- v3: leading emoji
  song   := regexp_replace(song, '^\d{1,2}[.)]\s+', '');               -- v3: "1. Song" in lists
  song   := regexp_replace(song, '^\s*(stream|watch|listen to)\s+', '', 'i');
  song   := nullif(btrim(song, ' "“”''‘’'), '');

  -- Named NDN events/series (2026-10-16). Events also match the whole title, so promo posts
  -- ("... premieres tonight on Harana Sa Manila") join their series.
  series := case
    when session ~* 'cozy cove fest'          then 'The Cozy Cove Fest'
    when coalesce(session, '') || ' ' || t ~* 'harana sa manila' then 'Harana sa Manila'
    when coalesce(session, '') || ' ' || t ~* 'alpas'            then 'Alpas La Union'
    when coalesce(session, '') || ' ' || t ~* 'new clark city'   then 'New Clark City Stadium'
    when session ~* 'session road'            then 'Live at Session Road'
    when session ~* 'taped sessions?'         then 'Taped Sessions'
    when session ~* 'cozy cove|cozy co|cozy cov|the cozy\s*$|cove coze|the cozy cozy' then 'Live at The Cozy Cove'   -- TikTok cuts captions short
    when session ~* '^\s*(live\s+)?(at|from|in)\M' then 'Other live shows'
    when session ~* 'session|harana'          then 'Other sessions'
    when song is not null                     then 'Other releases'
    else 'Other' end;
end;
$$;

------------------------------------------------------------------ 3. mart: Instagram views (Reels) instead of null
-- Same as 007_instagram_mart.sql except the Instagram rows now carry i.views.
create or replace view mart.dim_video as
with yt_latest as (
  select distinct on (video_id) * from staging.youtube_video_snapshot order by video_id, snapshot_date desc
), tt_latest as (
  select distinct on (video_id) * from staging.tiktok_video_snapshot order by video_id, snapshot_date desc
), ig_latest as (
  select distinct on (post_id) * from staging.instagram_post_snapshot order by post_id, snapshot_date desc
), unioned as (
  select 'YouTube' as platform, y.video_id, y.title as title,
         'https://www.youtube.com/watch?v=' || y.video_id as url,
         y.published_at, y.duration_sec,
         case when y.duration_sec <= 60 then 'Short (<=60 s)' else 'Full video' end as format,
         y.views as latest_views, y.likes as latest_likes, y.comments as latest_comments,
         y.snapshot_date as latest_snapshot
  from yt_latest y
  union all
  select 'TikTok', t.video_id, t.caption, t.url, t.published_at, t.duration_sec, 'TikTok clip',
         t.views, t.likes, t.comments, t.snapshot_date
  from tt_latest t
  union all
  select 'Instagram', i.post_id, i.caption, i.url, i.published_at, null::int,
         case when i.product_type = 'REELS' then 'Instagram Reel'
              when i.media_type = 'CAROUSEL_ALBUM' then 'Instagram carousel'
              else 'Instagram post' end,
         i.views, i.likes, i.comments, i.snapshot_date
  from ig_latest i
)
select u.platform, u.video_id, u.title, u.url,
       u.published_at,
       (u.published_at at time zone 'Asia/Manila')::date              as published_date_ph,
       to_char(u.published_at at time zone 'Asia/Manila', 'Dy')        as published_weekday_ph,
       extract(isodow from u.published_at at time zone 'Asia/Manila')::int as published_weekday_num,
       extract(hour from u.published_at at time zone 'Asia/Manila')::int   as published_hour_ph,
       u.duration_sec, u.format,
       p.series, p.session, p.song, p.artist,
       lower(regexp_replace(coalesce(p.song, ''), '[^[:alnum:]]', '', 'g'))
         || '|' || lower(regexp_replace(coalesce(p.artist, ''), '[^[:alnum:]]', '', 'g')) as song_key,
       (u.title ~* 'cozy cove')                                         as mentions_cozy_cove,
       u.latest_views, u.latest_likes, u.latest_comments, u.latest_snapshot
from unioned u
cross join lateral mart.parse_title(u.title) p;

------------------------------------------------------------------ mart: daily video facts (real + synthetic)
create or replace view mart.fact_video_daily as
with yt as (
  select 'YouTube' as platform, video_id, snapshot_date, views, likes, comments,
         null::bigint as shares, null::bigint as saves, 'real' as data_source
  from staging.youtube_video_snapshot
  union all
  select 'YouTube', video_id, snapshot_date, views, likes, comments, null, null, 'synthetic'
  from synthetic.youtube_video_daily
  where snapshot_date < (select min(snapshot_date) from raw.youtube_runs)
), tt as (
  select 'TikTok', video_id, snapshot_date, views, likes, comments, shares, saves, 'real'
  from staging.tiktok_video_snapshot
  union all
  select 'TikTok', video_id, snapshot_date, views, likes, comments, shares, saves, 'synthetic'
  from synthetic.tiktok_video_daily
  where snapshot_date < (select min(snapshot_date) from raw.tiktok_runs)
), ig as (
  select 'Instagram', post_id, snapshot_date, views, likes, comments, null::bigint, null::bigint, 'real'
  from staging.instagram_post_snapshot
), allrows as (select * from yt union all select * from tt union all select * from ig)
select a.platform, a.video_id, a.snapshot_date, a.data_source,
       a.views, a.likes, a.comments, a.shares, a.saves,
       a.views - lag(a.views) over w                                    as views_gained,
       a.likes - lag(a.likes) over w                                    as likes_gained,
       a.snapshot_date - (d.published_at at time zone 'UTC')::date      as days_since_upload
from allrows a
join mart.dim_video d on d.platform = a.platform and d.video_id = a.video_id
window w as (partition by a.platform, a.video_id order by a.snapshot_date);

comment on view mart.fact_video_daily is
  'Daily metrics per video/post. data_source = real (raw snapshots) or synthetic (invented backfill before the first real snapshot; YouTube/TikTok only). Instagram: views for Reels from 2026-10-21 (incl. paid and crossposted Facebook views), likes null when hidden.';

------------------------------------------------------------------ 4. one row per Instagram post (latest snapshot)
-- caption_type follows INSTAGRAM_QUESTIONS.md Q11; hashtag_count for Q8.
create or replace view staging.instagram_post_latest as
select p.post_id, p.url, p.caption, p.published_at, p.snapshot_date as latest_snapshot,
       case when p.product_type = 'REELS' then 'Reel'
            when p.media_type = 'CAROUSEL_ALBUM' then 'Carousel'
            when p.media_type = 'VIDEO' then 'Feed video' else 'Photo' end          as format,
       case when p.caption ~* 'premiere'                                              then 'Premiere teaser'
            when p.caption ~* 'now streaming|tune in now|is now (out|available)|out now' then 'Now streaming'
            when p.caption ~* '\mperforms?\M'                                         then 'Performance clip'
            when p.caption ~* 'ticket|line-?up|presale|gates open|see you'            then 'Event / tickets'
            else 'Other' end                                                          as caption_type,
       (select count(*) from regexp_matches(coalesce(p.caption, ''), '#\w+', 'g'))::int as hashtag_count,
       p.views, p.likes, p.comments, p.reposts, p.total_likes, p.total_comments
from (select distinct on (post_id) * from staging.instagram_post_snapshot
      order by post_id, snapshot_date desc) p;
