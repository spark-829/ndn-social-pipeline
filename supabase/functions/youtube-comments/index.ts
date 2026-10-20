// Supabase Edge Function: YouTube top-level comments for the fan-request analysis (sql/018_youtube_comments.sql,
// FAN_REQUESTS.md).
//   POST ?by=pg_cron            works through staging.youtube_comment_todo for ~100 s, answers {more: true|false}
//   POST ?limit=5               only the first N videos of the to-do list (testing)
//   GET  ?part=status           to-do counts, no API calls
// pg_cron: Tue 11:30/11:35/11:40 PH. Calls with nothing to do exit at once and log nothing.
// commentThreads.list, order=time (newest first), 100 per page = 1 quota unit. A fetch stops at the
// newest comment a finished fetch already stored (newest_at), so weekly runs only read new comments.
// Secrets: YOUTUBE_API_KEY (Edge Function secret); caller sends x-cron-secret (vault 'ndn_cron_secret').
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const API = "https://www.googleapis.com/youtube/v3";
const BUDGET_MS = 100_000, PARALLEL = 4;

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });
const key = () => (Deno.env.get("YOUTUBE_API_KEY") ?? "").trim();
const redact = (s: string) => (key() ? s.split(key()).join("REDACTED") : s);
let units = 0, quotaHit = false;

class ApiError extends Error {
  constructor(public status: number, public body: string) { super(`HTTP ${status}: ${body.slice(0, 200)}`); }
}

async function api(params: Record<string, string>) {
  const url = `${API}/commentThreads?` + new URLSearchParams({ ...params, key: key() });
  for (let attempt = 1; attempt <= 3; attempt++) {
    const resp = await fetch(url);
    const text = await resp.text();
    if (resp.status === 200) { units++; return JSON.parse(text); }
    if ((resp.status === 429 || resp.status >= 500) && attempt < 3) { await new Promise((r) => setTimeout(r, 2000 * attempt)); continue; }
    throw new ApiError(resp.status, redact(text));
  }
}

const keep = (t: any) => {
  const s = t.snippet.topLevelComment.snippet;
  return { comment_id: t.id, video_id: t.snippet.videoId, comment: {
    text: s.textOriginal ?? s.textDisplay ?? "", published_at: s.publishedAt, updated_at: s.updatedAt,
    likes: s.likeCount ?? 0, replies: t.snippet.totalReplyCount ?? 0,
    author_channel_id: s.authorChannelId?.value ?? null } };
};

// One video: read pages newest first until the stop point, the end, the time budget or the quota.
async function fetchVideo(v: any, deadline: number) {
  const stopAt = v.newest_at ? new Date(v.newest_at).getTime() : null;
  let token: string | null = v.page_token ?? null;
  let runNewest = v.run_newest_at ? new Date(v.run_newest_at).getTime() : 0;
  let saved = 0, done = false;
  try {
    while (!done) {
      if (Date.now() > deadline || quotaHit) break;
      let j: any;
      try {
        j = await api({ part: "snippet", videoId: v.video_id, maxResults: "100", order: "time",
                        textFormat: "plainText", ...(token ? { pageToken: token } : {}) });
      } catch (e) {
        // an old page token can expire: start this video again from the newest comment
        if (e instanceof ApiError && e.status === 400 && token && /pageToken/i.test(e.body)) { token = null; continue; }
        if (e instanceof ApiError && e.body.includes("quotaExceeded")) { quotaHit = true; break; }   // keep the place
        throw e;
      }
      const rows = [];
      for (const t of j.items ?? []) {
        const r = keep(t);
        const at = new Date(r.comment.published_at).getTime();
        if (stopAt !== null && at <= stopAt) { done = true; break; }
        runNewest = Math.max(runNewest, at);
        rows.push(r);
      }
      if (rows.length) {
        await sql`insert into raw.youtube_comments (comment_id, video_id, comment)
          select x->>'comment_id', x->>'video_id', x->'comment' from jsonb_array_elements(${sql.json(rows)}) x
          on conflict (comment_id) do update set fetched_at = now(), comment = excluded.comment`;
        saved += rows.length;
      }
      token = j.nextPageToken ?? null;
      if (!token) done = true;
    }
    const newest = runNewest ? new Date(runNewest).toISOString() : null;
    if (done) {
      await sql`insert into raw.youtube_comment_fetch (video_id, status, count_at_fetch, newest_at, saved)
        values (${v.video_id}, 'ok', ${v.count_now}, ${newest ?? v.newest_at ?? null}, ${saved})
        on conflict (video_id) do update set fetched_at = now(), status = 'ok', count_at_fetch = excluded.count_at_fetch,
          newest_at = greatest(raw.youtube_comment_fetch.newest_at, excluded.newest_at), page_token = null,
          run_newest_at = null, saved = raw.youtube_comment_fetch.saved + excluded.saved, error = null`;
    } else {
      await sql`insert into raw.youtube_comment_fetch (video_id, status, count_at_fetch, newest_at, page_token, run_newest_at, saved)
        values (${v.video_id}, 'partial', ${v.count_at_fetch ?? null}, ${v.newest_at ?? null}, ${token}, ${newest}, ${saved})
        on conflict (video_id) do update set fetched_at = now(), status = 'partial', page_token = excluded.page_token,
          run_newest_at = excluded.run_newest_at, saved = raw.youtube_comment_fetch.saved + excluded.saved, error = null`;
    }
    return { saved, done };
  } catch (e) {
    const body = e instanceof ApiError ? e.body : String(e);
    const disabled = body.includes("commentsDisabled");
    await sql`insert into raw.youtube_comment_fetch (video_id, status, count_at_fetch, newest_at, saved, error)
      values (${v.video_id}, ${disabled ? "disabled" : "error"}, ${v.count_now}, ${v.newest_at ?? null}, ${saved},
              ${disabled ? null : body.slice(0, 300)})
      on conflict (video_id) do update set fetched_at = now(), status = excluded.status, count_at_fetch = excluded.count_at_fetch,
        page_token = null, run_newest_at = null, saved = raw.youtube_comment_fetch.saved + excluded.saved, error = excluded.error`;
    return { saved, done: true, status: disabled ? "disabled" : "error" };
  }
}

async function run(limit: number | null) {
  const deadline = Date.now() + BUDGET_MS;
  // half-done videos first, then the newest videos (their comments are the freshest requests)
  const todo = await sql`select * from staging.youtube_comment_todo
    order by (reason = 'resume') desc, published_at desc ${limit ? sql`limit ${limit}` : sql``}`;
  let i = 0, videos = 0, finished = 0, saved = 0, disabled = 0, errors = 0;
  const worker = async () => {
    while (i < todo.length && Date.now() < deadline && !quotaHit) {
      const v = todo[i++];
      const r: any = await fetchVideo(v, deadline);
      videos++; saved += r.saved;
      if (r.done) finished++;
      if (r.status === "disabled") disabled++;
      if (r.status === "error") errors++;
    }
  };
  await Promise.all(Array.from({ length: PARALLEL }, worker));
  const [{ left }] = await sql`select count(*)::int as left from staging.youtube_comment_todo`;
  return { todo: todo.length, videos, finished, saved, disabled, errors, units, quota_hit: quotaHit, left };
}

async function logRun(by: string, status: string, detail: unknown) {
  await sql`insert into raw.music_runs (part, run_by, finished_at, status, detail)
    values ('youtube_comments', ${by}, now(), ${status}, ${sql.json(detail as any)})`;
}

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const url = new URL(req.url);
  const by = url.searchParams.get("by") ?? "manual";
  const limit = Number(url.searchParams.get("limit")) || null;
  units = 0; quotaHit = false;
  try {
    if (url.searchParams.get("part") === "status") {
      const rows = await sql`select reason, count(*)::int as videos, sum(count_now)::int as comments_now
        from staging.youtube_comment_todo group by 1 order by 1`;
      return Response.json({ todo: rows });
    }
    if (!key()) return new Response("YOUTUBE_API_KEY secret missing", { status: 500 });
    const detail = await run(limit);
    if (detail.todo === 0) return Response.json({ status: "nothing_to_do", more: false });
    const status = detail.quota_hit ? "quota" : detail.errors ? "partial_errors" : "ok";
    await logRun(by, status, detail);
    return Response.json({ status, more: detail.left > 0 && !detail.quota_hit, ...detail });
  } catch (e) {
    const msg = redact(String((e as Error)?.message ?? e)).slice(0, 500);
    await logRun(by, "failed", { error: msg, units }).catch(() => {});
    return Response.json({ status: "failed", error: msg }, { status: 500 });
  }
});
