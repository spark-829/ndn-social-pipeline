# Step 6b: TikTok official API (owner-authorized)

The scraper in Step 6 reads TikTok's public pages. This step adds the **official** route: TikTok API for Business, "TikTok accounts" scope. It only works for an account whose owner clicks **Allow**: NDN once they agree, or your own TikTok switched to a Business account for testing. The scraper keeps running; nothing in Step 6 changes.

Status: code written and tested offline (6 tests pass, both functions type-check). **Not deployed.** Waiting for TikTok to approve the app.

## OAuth in plain words

You never see the owner's password. Instead:

1. You send the owner an **invite link**.
2. The link sends them to TikTok, which asks "Let NDN social analytics read your videos and stats?"
3. They click **Allow**. TikTok sends their browser back to your **redirect URL** with a one-time **auth code** in the address.
4. Your callback function swaps that code (plus your app's secret) for two tokens:
   - **access token**: the key for API calls. Expires in about a day.
   - **refresh token**: used to get a new access token without asking the owner again. Lasts much longer.
5. Every day the snapshot job uses the access token, refreshing it first when it's close to expiring.

The **state** value is a random one-time ticket created when the invite link is opened. The callback only accepts a code that comes back with a ticket it issued in the last 15 minutes, so nobody can forge a callback.

## Files

| File | What it does |
|---|---|
| `sql/027_tiktok_business_api.sql` | tables `raw.tiktok_api_tokens` (secret, locked down), `raw.tiktok_api_oauth_state`, `raw.tiktok_api_responses` (untouched API JSON per page per day), `raw.tiktok_api_runs`; the daily cron block (commented out until someone authorizes) |
| `supabase/functions/_shared/tiktok_business.ts` | token exchange, token refresh, API GET with retries, video pagination, sign-in URL builder |
| `supabase/functions/_shared/tiktok_business_test.ts` | 6 offline tests with a fake TikTok |
| `supabase/functions/tiktok-oauth-callback/index.ts` | invite link → TikTok consent → saves tokens |
| `supabase/functions/tiktok-business-snapshot/index.ts` | daily job: refresh token if needed → `/business/get/` → `/business/video/list/` (20 per page) → raw tables |

Endpoints used: `POST /open_api/v1.3/tt_user/oauth2/token/`, `POST /open_api/v1.3/tt_user/oauth2/refresh_token/`, `GET /open_api/v1.3/business/get/`, `GET /open_api/v1.3/business/video/list/`. Sign-in page: `https://www.tiktok.com/v2/auth/authorize/`.

## Things to confirm once the portal opens up (TikTok's docs page is JavaScript-only, so these weren't readable)

1. **Scope names.** The default is `user.info.basic,user.insights,video.list,video.insights`. If the portal shows a ready-made **TikTok account holder authorization URL**, copy it into the `TIKTOK_AUTH_URL` secret instead; the function then uses it as-is and only adds the state.
2. **Field names.** Defaults: account `username, display_name, profile_image, followers_count, is_business_account`; video `item_id, create_time, caption, share_url, thumbnail_url, video_duration, video_views, likes, comments, shares, reach`. If TikTok rejects one, the error is saved in `raw.tiktok_api_runs.error`. Change the list with the `TIKTOK_ACCOUNT_FIELDS` / `TIKTOK_VIDEO_FIELDS` secrets (JSON array), no redeploy needed, then rerun with `force=1`.
3. **Refresh endpoint.** `tt_user/oauth2/refresh_token/` is from memory of TikTok's docs. If the first refresh fails, the token row shows `status = refresh_failed` with the message.

## Setup after TikTok approves the app

1. Copy the **App ID** and **Secret** from the portal. Don't paste them in chat.
2. Supabase dashboard → Edge Functions → Secrets → add `TIKTOK_APP_ID` and `TIKTOK_APP_SECRET`. (Optional: `TIKTOK_AUTH_URL`.)
3. Apply `sql/027_tiktok_business_api.sql` (first part only; leave the cron block commented).
4. Create the invite code in the SQL editor:
   ```sql
   select vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'tiktok_oauth_invite');
   select decrypted_secret from vault.decrypted_secrets where name = 'tiktok_oauth_invite';
   ```
5. Deploy both functions with **JWT verification off** (a browser redirect has no Supabase login, and the snapshot job checks `x-cron-secret` itself):
   ```
   supabase functions deploy tiktok-oauth-callback --no-verify-jwt
   supabase functions deploy tiktok-business-snapshot --no-verify-jwt
   ```
   (or ask Claude to deploy them through the Supabase connector; include the `_shared` file).
6. Make sure the portal's **TikTok account holder redirect URL** is exactly
   `https://bxjlpgzzowmbioowujug.supabase.co/functions/v1/tiktok-oauth-callback`
7. Test with your own Business account: open
   `https://bxjlpgzzowmbioowujug.supabase.co/functions/v1/tiktok-oauth-callback?invite=<code>` → Allow → "Connected".
8. Run the snapshot once by hand (PowerShell, `NDN_CRON_SECRET` from your `.env`):
   ```
   curl.exe -X POST "https://bxjlpgzzowmbioowujug.supabase.co/functions/v1/tiktok-business-snapshot?by=manual" -H "x-cron-secret: <secret>"
   ```
9. If it says `ok`, uncomment and run the cron block in `027` (daily 01:30 UTC = 9:30 am PH).
10. When NDN agrees, send them the same invite link. Their account appears as a second row in `raw.tiktok_api_tokens`.

## Exercises

1. In `tiktok_business.ts`, find where a response with HTTP 200 is still treated as an error. Why does TikTok need that check?
2. Why is the refresh done when the token expires *within an hour*, not when it has already expired?
3. Open `raw.tiktok_api_responses` after the first run. Compare one video's `video_views` with the same video in the scraper data (`raw.tiktok_responses`). Which one rounds big numbers?
4. What would happen if the callback skipped the `state` check? Describe the attack in one sentence.
5. Revoke the app from your TikTok settings, then run the snapshot. What does `raw.tiktok_api_tokens.status` say?
