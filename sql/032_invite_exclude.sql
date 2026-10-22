-- 032 (Vic 2026-10-23): Claude filters the invite list too. raw.invite_exclude holds artists who can't do a Cozy Cove
-- session (TV hosts, novelty acts) and old viral songs trending again as memes ("past trending"). They are removed
-- BEFORE the OPM top 30 is taken, so the next songs move up. Claude adds rows with a reason (added_by 'claude'); Vic can
-- add or switch rows off (active = false). spotify_id null = the title for any artist; title_key null = the whole artist.

create table if not exists raw.invite_exclude (
  id         bigserial primary key,
  spotify_id text,                        -- null = any artist (song-level rule)
  title_key  text,                        -- null = the whole artist; else staging.title_key(song)
  label      text not null,               -- what it is, for people reading the table
  reason     text not null,
  added_by   text not null default 'claude' check (added_by in ('claude', 'vic')),
  active     boolean not null default true,
  added_at   timestamptz not null default now(),
  check (spotify_id is not null or title_key is not null)
);

insert into raw.invite_exclude (spotify_id, title_key, label, reason, added_by)
select * from (values
  ('0ZXi1NG0Wwlaj70Qn25mAr', null, 'Willie Revillame (artist)',
   'TV host; "Syempre" is a novelty/TV song, not a live music act for Live at The Cozy Cove (Vic''s example)', 'vic'),
  (null, staging.title_key('Puede Nang Mangarap'), 'Puede Nang Mangarap (song, any artist)',
   'old viral song trending again ("past trending", Vic''s example); Spotify credits it to Lyca Gairanod', 'vic')
) x(spotify_id, title_key, label, reason, added_by)
where not exists (select 1 from raw.invite_exclude e where e.label = x.label);

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
), kept as (   -- sql/032: drop excluded artists / songs before taking 30, so the next songs move up
  select s.* from s
  where not exists (select 1 from raw.invite_exclude e
                    where e.active
                      and (e.spotify_id is null or e.spotify_id = s.spotify_id)
                      and (e.title_key is null or e.title_key = s.title_key))
)
select r.* from (
  select row_number() over (order by points desc, coalesce(top50_pos, 999), coalesce(billboard_pos, 999)) as rank,
         staging.name_key(artist) || '|' || title_key as song_key, s.*,
         exists (select 1 from staging.ndn_youtube_song n
                 where n.spotify_id = s.spotify_id and (n.title_key = s.title_key or n.track_id = s.track_id)) as on_ndn
  from kept s) r
where r.rank <= 30;

