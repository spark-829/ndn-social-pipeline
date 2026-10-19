// Supabase Edge Function: serves the dashboard tables to the Google Sheet (Apps Script in google_sheets/),
// which Tableau Public reads and refreshes daily. Read-only.
//
// GET ?t=account | video | songs | insights | tiktok | hashtags | scorecard   ->   {"columns": [...], "rows": [[...], ...]}
// Caller must send header x-cron-secret matching vault secret 'ndn_cron_secret' (same check as the other functions).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false });

// Same column lists as export_tableau.py, so the CSV and Google Sheets versions match field for field.
const QUERIES: Record<string, string> = {
  account: `select platform, snapshot_date::text, data_source, followers, followers_gained, total_views, views_gained,
                   video_count, hearts
            from mart.fact_account_daily order by platform, snapshot_date`,
  video: `select platform, video_id, title, url, published_at::text, published_date_ph::text, published_weekday_ph,
                 published_weekday_num, published_hour_ph, duration_sec, format, series, session, song, artist, song_key,
                 mentions_cozy_cove::text, latest_views, latest_likes, latest_comments, latest_snapshot::text, age_days,
                 views_per_day, likes_per_day, perf_per_day, engagement_rate, vs_series_median
          from mart.tableau_dim_video order by platform, published_at`,
  songs: `select song_key, song, artist, youtube_views, tiktok_views, instagram_likes, youtube_videos, tiktok_videos,
                 instagram_posts, case when is_cozy_cove then 't' else 'f' end as is_cozy_cove
          from mart.tableau_song_compare order by youtube_views desc nulls last`,
  insights: `select as_of::text, slot, sort_order, text, written_by from mart.insights
             where as_of = (select max(as_of) from mart.insights) order by sort_order`,
  // dashboard v2 (sql/012_dashboard_v2.sql)
  tiktok: `select video_id, url, left(regexp_replace(caption, '[[:space:]]+', ' ', 'g'), 300) as caption, published_at::text, published_date_ph::text, weekday_ph,
                 weekday_num, hour_ph, time_window, posts_that_day, duration_sec, length_group, views, likes, comments,
                 shares, saves, latest_snapshot::text, age_days, case when is_mature then 'yes' else 'no' end as is_mature,
                 case when is_last_30d then 'yes' else 'no' end as is_last_30d, likes_per_1k, comments_per_1k,
                 shares_per_1k, saves_per_1k, share_save_per_1k, share_save_group, neighbour_median, perf_index,
                 index_band, views_gained_7d, gained_since::text, caption_type,
                 case when asks_question then 'yes' else 'no' end as asks_question, n_hashtags, hashtag_group, track,
                 sound_type, song, artist, series
          from mart.tableau_tiktok_video order by published_at`,
  hashtags: `select hashtag, videos, median_index, breakout_pct, median_views from mart.tableau_tiktok_hashtag order by videos desc`,
  scorecard: `select platform, as_of::text, window_start::text, window_days, metric_name, followers, followers_change,
                 followers_change_pct, metric_gained, posts_in_window, left(regexp_replace(best_post, '[[:space:]]+', ' ', 'g'), 120) as best_post, best_post_url,
                 best_post_gained
          from mart.tableau_platform_scorecard order by followers desc`,
};

Deno.serve(async (req) => {
  const [{ secret }] = await sql`
    select decrypted_secret as secret from vault.decrypted_secrets where name = 'ndn_cron_secret'`;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  const t = new URL(req.url).searchParams.get("t") ?? "";
  const query = QUERIES[t];
  if (!query) return new Response(`t must be one of: ${Object.keys(QUERIES).join(", ")}`, { status: 400 });

  const result = await sql.unsafe(query).values();          // arrays, not objects: smaller payload
  const columns = result.columns.map((c: { name: string }) => c.name);
  // numerics arrive as strings from postgres; send numbers so Sheets/Tableau type them correctly
  const numeric = result.columns.map((c: { type: number }) => [20, 21, 23, 700, 701, 1700].includes(c.type));
  const rows = result.map((r: unknown[]) => r.map((v, i) => (numeric[i] && v !== null ? Number(v) : v)));
  return new Response(JSON.stringify({ columns, rows }), { headers: { "Content-Type": "application/json" } });
});
