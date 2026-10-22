// Offline tests for the TikTok Business API helpers (no network, fake fetch).
// Run:  deno test supabase/functions/_shared/tiktok_business_test.ts
// Tiny local asserts (no external deps, so the test also runs offline).
function assert(c: unknown, msg = "assertion failed"): asserts c { if (!c) throw new Error(msg); }
function assertEquals(a: unknown, b: unknown) {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`expected ${y}\n     got ${x}`);
}
async function assertRejects(fn: () => Promise<unknown>, cls: new (...a: any[]) => Error, includes: string) {
  try { await fn(); } catch (e) {
    assert(e instanceof cls, `wrong error type: ${e}`);
    assert(String((e as Error).message).includes(includes), `message lacks "${includes}": ${(e as Error).message}`);
    return;
  }
  throw new Error("expected a rejection");
}
import {
  buildAuthorizeUrl, exchangeCode, listAllVideos, refreshToken, TikTokApiError,
} from "./tiktok_business.ts";

type Call = { url: string; init?: RequestInit };
function fakeFetch(handler: (url: URL, init?: RequestInit) => unknown, calls: Call[] = []) {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    calls.push({ url: url.toString(), init });
    return new Response(JSON.stringify(handler(url, init)), { status: 200 });
  }) as typeof fetch;
}

const tokenData = {
  open_id: "OPEN123", access_token: "AT", refresh_token: "RT", scope: "video.list",
  expires_in: 86400, refresh_token_expires_in: 31536000,
};

Deno.test("exchangeCode posts the code and parses tokens", async () => {
  const calls: Call[] = [];
  const f = fakeFetch(() => ({ code: 0, message: "OK", data: tokenData }), calls);
  const t = await exchangeCode("APP", "SECRET", "CODE1", "https://x/cb", f);
  assertEquals(t.open_id, "OPEN123");
  assertEquals(t.access_token, "AT");
  assert(t.access_expires_at.getTime() > Date.now() + 86000_000);
  assert(calls[0].url.endsWith("/tt_user/oauth2/token/"));
  const body = JSON.parse(String(calls[0].init?.body));
  assertEquals(body, { client_id: "APP", client_secret: "SECRET", grant_type: "authorization_code",
                       auth_code: "CODE1", redirect_uri: "https://x/cb" });
});

Deno.test("exchangeCode throws on a TikTok error code even with HTTP 200", async () => {
  const f = fakeFetch(() => ({ code: 40102, message: "auth_code expired" }));
  await assertRejects(() => exchangeCode("A", "S", "C", "R", f), TikTokApiError, "40102");
});

Deno.test("refreshToken uses the refresh endpoint", async () => {
  const calls: Call[] = [];
  const f = fakeFetch(() => ({ code: 0, message: "OK", data: { ...tokenData, access_token: "AT2" } }), calls);
  const t = await refreshToken("APP", "SECRET", "RT", f);
  assertEquals(t.access_token, "AT2");
  assert(calls[0].url.endsWith("/tt_user/oauth2/refresh_token/"));
  assertEquals(JSON.parse(String(calls[0].init?.body)).grant_type, "refresh_token");
});

Deno.test("listAllVideos follows the cursor and saves every page", async () => {
  const calls: Call[] = [];
  const total = 45; // 3 pages of 20/20/5
  const f = fakeFetch((url) => {
    const start = Number(url.searchParams.get("cursor") ?? 0);
    const n = Math.min(20, total - start);
    return { code: 0, message: "OK", data: {
      videos: Array.from({ length: n }, (_, i) => ({ item_id: String(start + i) })),
      cursor: start + n, has_more: start + n < total } };
  }, calls);
  const saved: number[] = [];
  const r = await listAllVideos("AT", "OPEN123", ["item_id"], async (p) => { saved.push(p); }, f);
  assertEquals(r, { videos: 45, pages: 3, error: null });
  assertEquals(saved, [1, 2, 3]);
  const first = new URL(calls[0].url);
  assertEquals(first.searchParams.get("business_id"), "OPEN123");
  assertEquals(first.searchParams.get("fields"), '["item_id"]');
  assertEquals((calls[0].init?.headers as Record<string, string>)["Access-Token"], "AT");
});

Deno.test("listAllVideos stops and reports a field error, keeping the error page", async () => {
  const f = fakeFetch(() => ({ code: 40002, message: "invalid field: reach" }));
  const saved: number[] = [];
  const r = await listAllVideos("AT", "B", ["reach"], async (p) => { saved.push(p); }, f);
  assertEquals(r.videos, 0);
  assertEquals(saved, [1]);
  assert(r.error?.includes("invalid field"));
});

Deno.test("buildAuthorizeUrl: default URL and portal URL", () => {
  const a = new URL(buildAuthorizeUrl({ appId: "APP", redirectUri: "https://x/cb", scopes: "video.list", state: "S1" }));
  assertEquals(a.origin + a.pathname, "https://www.tiktok.com/v2/auth/authorize/");
  assertEquals(a.searchParams.get("client_key"), "APP");
  assertEquals(a.searchParams.get("state"), "S1");
  assertEquals(a.searchParams.get("response_type"), "code");

  const b = new URL(buildAuthorizeUrl({ appId: "APP", redirectUri: "https://x/cb", scopes: "", state: "S2",
    portalUrl: "https://www.tiktok.com/v2/auth/authorize/?client_key=APP&scope=a,b&redirect_uri=https%3A%2F%2Fx%2Fcb&state=old" }));
  assertEquals(b.searchParams.get("state"), "S2");
  assertEquals(b.searchParams.get("scope"), "a,b");
});
