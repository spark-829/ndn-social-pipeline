// Supabase Edge Function: daily YouTube snapshot for Nine Degrees North.
// Same logic as extract_youtube.py, but it runs inside Supabase and writes
// straight into raw.youtube_responses instead of JSON files (Extract + Load).
//
// Called once a day by pg_cron, and again by GitHub Actions as a keep-alive.
// It is idempotent: if today's run already exists, it returns without calling YouTube.
//
// Secrets: YOUTUBE_API_KEY (Edge Function secret, set in the dashboard).
//          Caller must send header x-cron-secret matching vault secret 'ndn_cron_secret'.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const API = "https://www.googleapis.com/youtube/v3";
const NDN_CHANNEL_ID = "UCNO66UYt0xSeEMw9d5v-37w";
const BATCH = 50;
const MAX_RETRIES = 4;
const CHANNEL_PARTS = "snippet,statistics,contentDetails,brandingSettings,topicDetails,status,localizations";
const VIDEO_PARTS = "snippet,statistics,contentDetails,status,topicDetails,recordingDetails," +
  "liveStreamingDetails,localizations,player,paidProductPlacementDetails";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });

class QuotaExceeded extends Error {}

const redact = (s: string, key: string) => s.split(key).join("REDACTED");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// v2 (sql/019, DB space): text that doesn't change day to day (description, localizations,
// thumbnails, player) is moved out of the daily reply into raw.youtube_video_static, which gets a
// row only for a new video or a changed field. snippet.localized is dropped when it is an exact
// copy of title + description (always so far). Daily reply: 1.19 MB -> 0.20 MB.
type Static = { video_id: string; description: string | null; localizations: unknown; thumbnails: unknown; player: unknown };
function splitStatic(payload: any, out: Static[]) {
  for (const it of payload.items ?? []) {
    const sn = it.snippet ?? {};
    out.push({ video_id: it.id, description: sn.description ?? null, localizations: it.localizations ?? null,
               thumbnails: sn.thumbnails ?? null, player: it.player ?? null });
    const loc = sn.localized;
    if (loc && Object.keys(loc).length === 2 && loc.title === sn.title && loc.description === sn.description) {
      delete sn.localized;
    }
    delete sn.description; delete sn.thumbnails; delete it.localizations; delete it.player;
  }
}

async function callApi(endpoint: string, params: Record<string, string>, key: string) {
  const url = `${API}/${endpoint}?` + new URLSearchParams({ ...params, key });
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    const resp = await fetch(url);
    const text = await resp.text();
    if (resp.status === 200) return { url: redact(url, key), payload: JSON.parse(text) };
    if (resp.status === 403 && text.includes("quotaExceeded")) {
      throw new QuotaExceeded("daily quota used up; try again after midnight Pacific time");
    }
    if ((resp.status === 429 || resp.status >= 500) && attempt < MAX_RETRIES) {
      await sleep(2 ** attempt * 1000);
      continue;
    }
    throw new Error(`${endpoint}: HTTP ${resp.status}: ${redact(text.slice(0, 300), key)}`);
  }
  throw new Error("unreachable");
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const triggeredBy = new URL(req.url).searchParams.get("by") ?? "manual";
  const key = (Deno.env.get("YOUTUBE_API_KEY") ?? "").trim();
  if (!key) return new Response("YOUTUBE_API_KEY secret missing", { status: 500 });

  const now = new Date();
  const snapshotDate = now.toISOString().slice(0, 10);            // UTC date, same as the Python script
  const stamp = now.toISOString().replace(/\.\d{3}Z$/, "+00:00");

  const done = await sql`select 1 from raw.youtube_runs where snapshot_date = ${snapshotDate}`;
  if (done.length) {
    return Response.json({ status: "already_done", snapshot_date: snapshotDate });
  }

  try {
    const files: { name: string; url: string; payload: unknown }[] = [];
    let units = 0;

    // 1) channel: stats + uploads playlist
    const ch = await callApi("channels", { part: CHANNEL_PARTS, id: NDN_CHANNEL_ID }, key);
    units++;
    files.push({ name: "channel", ...ch });
    const uploads = ch.payload.items?.[0]?.contentDetails?.relatedPlaylists?.uploads;
    if (!uploads) throw new Error(`channel ${NDN_CHANNEL_ID} not found`);

    // 2) every video ID from the uploads playlist (lookup only, not stored)
    const ids: string[] = [];
    let token: string | undefined, pages = 0;
    do {
      const params: Record<string, string> = { part: "contentDetails", playlistId: uploads, maxResults: String(BATCH) };
      if (token) params.pageToken = token;
      const res = await callApi("playlistItems", params, key);
      units++; pages++;
      ids.push(...(res.payload.items ?? []).map((it: any) => it.contentDetails.videoId));
      token = res.payload.nextPageToken;
    } while (token);

    // 3) full details for every video, 50 IDs per call
    const statics: Static[] = [];
    for (let i = 0; i < ids.length; i += BATCH) {
      const res = await callApi("videos", { part: VIDEO_PARTS, id: ids.slice(i, i + BATCH).join(",") }, key);
      units++;
      splitStatic(res.payload, statics);
      files.push({ name: `videos_${String(i / BATCH + 1).padStart(3, "0")}`, ...res });
    }

    // Load: all files + the run row in ONE transaction, so a day is all-or-nothing.
    await sql.begin(async (tx) => {
      for (const f of files) {
        await tx`
          insert into raw.youtube_responses (snapshot_date, file_name, extracted_at, request_url, payload)
          values (${snapshotDate}, ${f.name}, ${stamp}, ${f.url}, ${tx.json(f.payload as any)})`;
      }
      await tx`
        insert into raw.youtube_video_static (video_id, seen_date, description, localizations, thumbnails, player)
        select s.video_id, ${snapshotDate}::date, s.description, s.localizations, s.thumbnails, s.player
        from jsonb_to_recordset(${tx.json(statics as any)}::jsonb)
             as s(video_id text, description text, localizations jsonb, thumbnails jsonb, player jsonb)
        left join lateral (select * from raw.youtube_video_static l where l.video_id = s.video_id
                           order by l.seen_date desc limit 1) l on true
        where l.video_id is null
           or (l.description, l.localizations, l.thumbnails, l.player)
              is distinct from (s.description, s.localizations, s.thumbnails, s.player)
        on conflict do nothing`;
      await tx`
        insert into raw.youtube_runs (snapshot_date, extracted_at, channel_id, videos, playlist_pages, quota_units_used, triggered_by)
        values (${snapshotDate}, ${stamp}, ${NDN_CHANNEL_ID}, ${ids.length}, ${pages}, ${units}, ${triggeredBy})`;
    });

    const summary = { status: "done", version: 2, snapshot_date: snapshotDate, videos: ids.length, playlist_pages: pages, quota_units_used: units };
    console.log(summary);
    return Response.json(summary);
  } catch (err) {
    const msg = err instanceof Error ? redact(err.message, key) : String(err);
    console.error("FAILED:", msg);
    return Response.json({ status: "failed", error: msg }, { status: err instanceof QuotaExceeded ? 429 : 500 });
  }
});
