-- 030 (Vic 2026-10-23): (1) the OPM top 30 skips songs NDN already posted on YouTube BEFORE taking 30, so every slot is
-- a song NDN could still film (029 picked 30 first and the invite gate then dropped 8 of them: Mahal Magmahal,
-- Kalapastangan, Multo, Panaginip, Pag-Ibig ay Kanibalismo II, Pahintulot, Paraluman, 1990).
-- (2) Fan uploads are found automatically (no pasting): top30_tiktok.py reads 3 Sounds-tab result pages plus the title
-- alone and "title sped up"; fan uploads ("original sound - someone") carry TikTok's "Contains music from" the song and
-- are kept like official sounds, other versions go to the caption vote. (TikTok's video search returned 0 videos even
-- logged in, probe5.log 2026-10-22, so it is not used; 'video_search' stays allowed for later.)

-- Songs on NDN's YouTube, by Spotify artist + title key (from the video's song tag) or by studio track id (the
-- session's matched Spotify track). Same two checks as the invite view's "on_ndn".
create or replace view staging.ndn_youtube_song as
select distinct va.spotify_id, staging.title_key(v.song) as title_key, null::text as track_id
from staging.video_artist va
join mart.tableau_dim_video v on v.platform = va.platform and v.video_id = va.video_id
where va.platform = 'YouTube' and v.song is not null
union
select distinct spotify_id, null, studio_track_id from staging.youtube_session_spotify where studio_track_id is not null;

create or replace view staging.invite_top30 as
with lists as (
  select t.playlist, t.position, t.song, t.track_id, t.artist_ids[1] as spotify_id, t.artists[1] as artist,
         case t.playlist when 'Top 50 - Philippines' then (51 - t.position) * 2 else greatest(101 - t.position, 0) end as points
  from staging.spotify_playlist_track t
  where t.playlist in ('Top 50 - Philippines', 'Viral Hits Philippines', 'Billboard Philippines Hot 100')
    and t.snapshot_date = (select max(x.snapshot_date) from staging.spotify_playlist_track x where x.playlist = t.playlist)
), s as (
  select l.spotify_id, staging.title_key(l.song) as title_key, min(l.song) as song, min(l.artist) as artist,
         min(l.track_id) as track_id, sum(l.points) as points,
         min(l.position) filter (where l.playlist = 'Top 50 - Philippines')          as top50_pos,
         min(l.position) filter (where l.playlist = 'Viral Hits Philippines')        as viral_pos,
         min(l.position) filter (where l.playlist = 'Billboard Philippines Hot 100') as billboard_pos
  from lists l
  where l.spotify_id in (select spotify_id from staging.opm_artist) and staging.title_key(l.song) <> ''
  group by 1, 2
), unposted as (
  select s.* from s
  where not exists (select 1 from staging.ndn_youtube_song n
                    where n.spotify_id = s.spotify_id and (n.title_key = s.title_key or n.track_id = s.track_id))
)
select r.* from (
  select row_number() over (order by points desc, coalesce(top50_pos, 999), coalesce(billboard_pos, 999)) as rank,
         staging.name_key(artist) || '|' || title_key as song_key, u.*
  from unposted u) r
where r.rank <= 30;

alter table raw.tiktok_trend_sound drop constraint if exists tiktok_trend_sound_added_from_check;
alter table raw.tiktok_trend_sound add constraint tiktok_trend_sound_added_from_check
  check (added_from in ('sounds_tab', 'vic_sheet', 'video_search'));
