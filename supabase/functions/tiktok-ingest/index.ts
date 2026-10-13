// Supabase Edge Function: receives one day's TikTok snapshot from extract_tiktok.py
// (run by GitHub Actions) and stores it untouched in raw.tiktok_responses + raw.tiktok_runs.
//
// The scraping happens outside Supabase (Python + yt-dlp can't run in Edge Functions);
// this function only does the Load. Same secret check as youtube-snapshot.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const FILES = ["profile", "videos"] as const;

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  if (req.method !== "POST") return new Response("expected POST", { status: 405 });
  const triggeredBy = new URL(req.url).searchParams.get("by") ?? "manual";

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response("body must be JSON", { status: 400 });
  }
  const { snapshot_date: day, summary, files } = body ?? {};
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day ?? "") || !summary || !FILES.every((f) => files?.[f]?.response)) {
    return new Response("expected {snapshot_date, summary, files: {profile, videos}}", { status: 400 });
  }

  const done = await sql`select 1 from raw.tiktok_runs where snapshot_date = ${day}`;
  if (done.length) return Response.json({ status: "already_done", snapshot_date: day });

  // All-or-nothing: both files + the run row in one transaction.
  await sql.begin(async (tx) => {
    for (const name of FILES) {
      const f = files[name];
      await tx`
        insert into raw.tiktok_responses (snapshot_date, file_name, extracted_at, source, request_url, payload)
        values (${day}, ${name}, ${f._meta?.extracted_at_utc ?? summary.extracted_at_utc},
                ${f._meta?.source ?? null}, ${f._meta?.request_url ?? null}, ${tx.json(f.response)})`;
    }
    await tx`
      insert into raw.tiktok_runs (snapshot_date, extracted_at, username, videos, followers, ytdlp_version, triggered_by)
      values (${day}, ${summary.extracted_at_utc}, ${summary.username}, ${summary.videos},
              ${summary.followers ?? null}, ${summary.ytdlp_version ?? null}, ${triggeredBy})`;
  });

  const result = { status: "done", snapshot_date: day, videos: summary.videos, followers: summary.followers };
  console.log(result);
  return Response.json(result);
});
