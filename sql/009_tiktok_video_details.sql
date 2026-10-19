-- 009: per-video TikTok details. The profile listing cuts captions off (hashtags arrive as
-- "#cozyc"), so extract_tiktok_details.py opens each video's page once and stores the full
-- caption plus TikTok's auto-captions file (WebVTT) when the video has one.

create table if not exists raw.tiktok_video_details (
  video_id      text primary key,
  fetched_at    timestamptz not null default now(),
  description   text,          -- full caption, untouched
  subtitle_lang text,          -- e.g. fil-PH; null when TikTok has no captions file
  subtitle_vtt  text,          -- the captions file, untouched
  info          jsonb          -- small subset of the yt-dlp result (track, artists, duration, ...)
);

-- Typed and cleaned: hashtags as an array, captions file reduced to plain transcript text.
create or replace view staging.tiktok_video_details as
select
  d.video_id,
  d.fetched_at,
  d.description as caption_full,
  coalesce(array(select lower(m[1]) from regexp_matches(coalesce(d.description, ''), '#([[:alnum:]_]+)', 'g') m),
           '{}') as hashtags,
  (select count(*) from regexp_matches(coalesce(d.description, ''), '#[[:alnum:]_]+', 'g'))::int as n_hashtags,
  coalesce(d.description, '') ~ '\?' as caption_asks_question,
  d.subtitle_lang,
  nullif(btrim(regexp_replace(
    regexp_replace(coalesce(d.subtitle_vtt, ''),
      '(^WEBVTT[^\n]*$|^[0-9:.]+ --> [^\n]*$|^[0-9]+$|<[^>]+>)', '', 'gm'),
    '\s+', ' ', 'g')), '') as transcript
from raw.tiktok_video_details d;
