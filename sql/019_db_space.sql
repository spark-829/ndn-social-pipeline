-- 019_db_space.sql  (DB space plan, Vic 2026-10-21; see docs/NDN_NOTES.md)
-- Part 1: YouTube text that doesn't change is stored ONCE per video, not in every daily reply.
--   Measured on 2026-10-20: one daily reply = 1.19 MB; without these fields = 0.20 MB (-83%).
--   The description was stored 3 times per video per day: snippet.description, snippet.localized
--   (an exact copy of title + description) and localizations (per-language title + description).
--   raw.youtube_video_static keeps description, localizations, thumbnails and player, one row per
--   video, plus a new row only if one of them changes (so an edited description is still kept).
--   youtube-snapshot v2 strips them before saving the daily reply; snippet.localized is dropped
--   only when it is an exact copy of title + description.
-- Part 2: synthetic backfill shrinks as real data grows: for every full month of real data, the
--   oldest month of synthetic data is deleted (pg_cron, 13th of each month, 02:00 PH), then
--   VACUUM FULL gives the space back (a plain delete would leave the space reserved for a table
--   that never gets new rows).

------------------------------------------------------------------ part 1: store-once table
create table if not exists raw.youtube_video_static (
  video_id      text  not null,
  seen_date     date  not null,          -- first snapshot that had this version
  description   text,
  localizations jsonb,
  thumbnails    jsonb,
  player        jsonb,
  primary key (video_id, seen_date)
);
alter table raw.youtube_video_static enable row level security;
comment on table raw.youtube_video_static is
  'YouTube video fields that rarely change, stored once per version (moved out of raw.youtube_responses daily replies, sql/019).';

-- One-off backfill from the replies already stored: a row for the first day and for every change.
insert into raw.youtube_video_static (video_id, seen_date, description, localizations, thumbnails, player)
select video_id, snapshot_date, description, localizations, thumbnails, player
from (
  select v.*, lag(row(description, localizations, thumbnails, player)::text)
              over (partition by video_id order by snapshot_date) as prev
  from (select distinct on (r.snapshot_date, i->>'id')
               r.snapshot_date, i->>'id' as video_id,
               i->'snippet'->>'description' as description, i->'localizations' as localizations,
               i->'snippet'->'thumbnails' as thumbnails, i->'player' as player
        from raw.youtube_responses r, jsonb_array_elements(r.payload->'items') i
        where r.file_name like 'videos\_%'
        order by r.snapshot_date, i->>'id') v
) x
where prev is null or prev is distinct from row(description, localizations, thumbnails, player)::text
on conflict do nothing;

-- Strip the stored replies (same rule as youtube-snapshot v2).
create or replace function raw.youtube_strip_static(item jsonb) returns jsonb
language sql immutable as $$
  select ((case when item->'snippet'->'localized' = jsonb_build_object('title', item->'snippet'->'title',
                                                                       'description', item->'snippet'->'description')
                then item #- '{snippet,localized}' else item end)
          #- '{snippet,description}' #- '{snippet,thumbnails}') - 'localizations'::text - 'player'::text
$$;

update raw.youtube_responses r
set payload = jsonb_set(r.payload, '{items}',
                (select jsonb_agg(raw.youtube_strip_static(i) order by n)
                 from jsonb_array_elements(r.payload->'items') with ordinality t(i, n)))
where r.file_name like 'videos\_%'
  and exists (select 1 from jsonb_array_elements(r.payload->'items') i
              where i->'snippet' ? 'description' or i ? 'localizations' or i ? 'player');

-- The details view now reads the description from the store-once table (latest version).
create or replace view staging.youtube_video_details as
select distinct on (i->>'id')
       i->>'id' as video_id, r.snapshot_date,
       s.description                                                  as description,
       (i->'contentDetails'->>'caption')::boolean                     as has_uploaded_captions,
       jsonb_array_length(coalesce(i->'snippet'->'tags', '[]'))       as tag_count,
       i->'snippet'->>'categoryId'                                    as category_id,
       i->'snippet'->>'defaultAudioLanguage'                          as audio_language,
       (i ? 'liveStreamingDetails')                                   as is_premiere,
       (i->'liveStreamingDetails'->>'scheduledStartTime')::timestamptz as premiere_scheduled,
       (i->'liveStreamingDetails'->>'actualStartTime')::timestamptz    as premiere_started,
       s.description ilike '%open.spotify.com%'                       as links_spotify,
       s.description ilike '%list=%'                                   as links_playlist
from raw.youtube_responses r
cross join jsonb_array_elements(r.payload->'items') i
left join lateral (select description from raw.youtube_video_static s
                   where s.video_id = i->>'id' order by s.seen_date desc limit 1) s on true
where r.file_name like 'videos\_%'
order by i->>'id', r.snapshot_date desc;

------------------------------------------------------------------ part 2: monthly synthetic trim
-- STATUS 2026-10-21: NOT APPLIED yet (part 1 is applied). Waiting for Vic's OK on the dashboard
-- history window; run this part before 2026-11-13.
-- Cutoff per platform = (first real day - 10 months) + (full months of real data so far).
-- Synthetic YouTube starts 2025-12-12 (real 2026-10-12), TikTok 2025-12-13 (real 2026-10-13),
-- so the first delete is on 2026-11-13 and removes Dec 12/13 - Jan 11/12. Safe to run any day:
-- it only deletes once another full month of real data exists.
create or replace function synthetic.trim_oldest_months() returns jsonb
language plpgsql as $$
declare
  yt_start date := (select min(snapshot_date) from raw.youtube_runs);
  tt_start date := (select min(snapshot_date) from raw.tiktok_runs);
  today    date := (now() at time zone 'Asia/Manila')::date;
  yt_cut date; tt_cut date; n_yt bigint; n_ytc bigint; n_tt bigint; n_tta bigint; result jsonb;
begin
  yt_cut := yt_start - interval '10 months'
            + make_interval(months => (extract(year from age(today, yt_start)) * 12 + extract(month from age(today, yt_start)))::int);
  tt_cut := tt_start - interval '10 months'
            + make_interval(months => (extract(year from age(today, tt_start)) * 12 + extract(month from age(today, tt_start)))::int);
  delete from synthetic.youtube_video_daily   where snapshot_date < yt_cut; get diagnostics n_yt  = row_count;
  delete from synthetic.youtube_channel_daily where snapshot_date < yt_cut; get diagnostics n_ytc = row_count;
  delete from synthetic.tiktok_video_daily    where snapshot_date < tt_cut; get diagnostics n_tt  = row_count;
  delete from synthetic.tiktok_account_daily  where snapshot_date < tt_cut; get diagnostics n_tta = row_count;
  result := jsonb_build_object('action', 'monthly_trim', 'youtube_cutoff', yt_cut, 'tiktok_cutoff', tt_cut,
              'deleted', jsonb_build_object('youtube_video_daily', n_yt, 'youtube_channel_daily', n_ytc,
                                            'tiktok_video_daily', n_tt, 'tiktok_account_daily', n_tta));
  if n_yt + n_ytc + n_tt + n_tta > 0 then
    insert into synthetic.generation_log (generated_at, seed, details) values (now(), 'trim', result);
  end if;
  return result;
end $$;

-- 13th of each month, 02:00 PH = 18:00 UTC on the 12th; VACUUM FULL 20 min later (own job:
-- VACUUM can't run inside a function or transaction).
select cron.schedule('ndn-synthetic-trim-monthly', '0 18 12 * *', $$select synthetic.trim_oldest_months()$$);
select cron.schedule('ndn-synthetic-vacuum-monthly', '20 18 12 * *',
  $$vacuum full synthetic.youtube_video_daily, synthetic.youtube_channel_daily, synthetic.tiktok_video_daily, synthetic.tiktok_account_daily$$);
