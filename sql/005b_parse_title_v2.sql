-- 005b_parse_title_v2.sql: title parser v2 (replaces the version in 005_staging_mart.sql)
-- Handles, in order:
--   "Song – Artist [Harana sa Manila]"            trailing [Series] becomes the session
--   "Artist performs 'Song' Live at The Cozy Cove" Shorts format (206 YouTube Shorts)
--   "Watch Artist's full performance of “Song” Live at ..."
--   "Song (Live at The Cozy Cove) - Artist"        main format; dash optional, "by" allowed
--   "Song - Artist"                                plain releases
-- Postgres regex note: a whole pattern is greedy or lazy depending on its FIRST quantifier, so patterns
-- start with a greedy piece and avoid lazy quantifiers.
create or replace function mart.parse_title(t text,
    out song text, out session text, out artist text, out series text)
language plpgsql immutable set search_path = '' as $$
declare
  m  text[];
  t2 text := btrim(coalesce(t, ''));
  br text;
begin
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

  -- TikTok captions continue after the artist: cut at the first sentence ending, hashtag or line break
  artist := regexp_replace(artist, '\s+(is now|is out|now streaming|out now|out on|premieres|streaming|available|drops|watch|full)\M.*$', '', 'i');
  artist := regexp_replace(artist, '\s*[!#\n].*$', '');
  artist := nullif(btrim(regexp_replace(artist, '[\s.,;:]+$', '')), '');
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
