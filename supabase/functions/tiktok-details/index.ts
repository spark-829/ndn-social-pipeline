// Supabase Edge Function: the Load side of extract_tiktok_details.py when it runs on GitHub
// Actions (no database password there, only NDN_CRON_SECRET).
//   GET  -> {video_ids: [...]}  videos in the latest snapshot that have no details row yet, newest first
//   POST {video_id, description, subtitle_lang, subtitle_vtt, info} -> upserts raw.tiktok_video_details
// Same secret check as tiktok-ingest.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }

  if (req.method === "GET") {
    const rows = await sql`
      select s.video_id::text as video_id
      from staging.tiktok_video_snapshot s
      left join raw.tiktok_video_details d using (video_id)
      where s.snapshot_date = (select max(snapshot_date) from staging.tiktok_video_snapshot)
        and d.video_id is null
      order by s.published_at desc`;
    return Response.json({ video_ids: rows.map((r) => r.video_id) });
  }
  if (req.method !== "POST") return new Response("expected GET or POST", { status: 405 });

  let row: any;
  try {
    row = await req.json();
  } catch {
    return new Response("body must be JSON", { status: 400 });
  }
  if (!/^\d+$/.test(row?.video_id ?? "") || typeof row.info !== "object") {
    return new Response("expected {video_id, description, subtitle_lang, subtitle_vtt, info}", { status: 400 });
  }

  await sql`
    insert into raw.tiktok_video_details (video_id, fetched_at, description, subtitle_lang, subtitle_vtt, info)
    values (${row.video_id}, now(), ${row.description ?? null}, ${row.subtitle_lang ?? null},
            ${row.subtitle_vtt ?? null}, ${sql.json(row.info)})
    on conflict (video_id) do update set fetched_at = now(), description = excluded.description,
      subtitle_lang = excluded.subtitle_lang, subtitle_vtt = excluded.subtitle_vtt, info = excluded.info`;
  return Response.json({ status: "saved", video_id: row.video_id });
});
