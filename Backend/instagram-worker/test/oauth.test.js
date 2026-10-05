import test from "node:test";
import assert from "node:assert/strict";
import worker, { InstagramConnection } from "../src/index.js";

function setup() {
  const objects = new Map(), media = new Map();
  const env = {
    PUBLIC_BASE_URL: "https://test.example", INSTAGRAM_API_VERSION: "v25.0",
    DOBBY_APP_API_KEY: "app-secret", INSTAGRAM_APP_ID: "instagram-app", INSTAGRAM_APP_SECRET: "instagram-secret",
    INSTAGRAM_MEDIA: { async put(k, v) { media.set(k, v); }, async get(k) { return media.get(k); } },
    INSTAGRAM_CONNECTIONS: {
      idFromName: name => name,
      get(id) {
        if (!objects.has(id)) {
          const data = new Map();
          const storage = { async get(k) { return structuredClone(data.get(k)); }, async put(k, v) { data.set(k, structuredClone(v)); }, async delete(k) { data.delete(k); }, async deleteAll() { data.clear(); } };
          objects.set(id, new InstagramConnection({ storage }, env));
        }
        return objects.get(id);
      }
    }
  };
  const call = (path, method = "GET", body, owner = "a".repeat(64), key = "app-secret") => worker.fetch(new Request(`https://test.example${path}`, {
    method, headers: { "X-Dobby-App-Key": key, Authorization: `Bearer ${owner}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body)
  }), env);
  return { env, call, objects };
}
function mockMeta(t, handler) {
  t.mock.method(globalThis, "fetch", async (url, options) => {
    const data = await handler(new URL(url), options);
    return Response.json(data);
  });
}
async function login(call) {
  const start = await (await call("/oauth/start", "POST")).json();
  const state = new URL(start.authorizationURL).searchParams.get("state");
  const response = await call(`/oauth/callback?code=test-code&state=${state}`);
  return { start, state, response };
}
function successMeta(url) {
  if (url.host === "api.instagram.com") return { access_token: "short-secret" };
  if (url.pathname === "/access_token") return { access_token: "long-secret", expires_in: 5184000 };
  if (url.pathname.endsWith("/me")) return { user_id: "123", username: "testshop", account_type: "BUSINESS" };
  if (url.pathname.endsWith("/media")) return { id: "container" };
  if (url.pathname.endsWith("/container")) return { status_code: "FINISHED" };
  if (url.pathname.endsWith("/media_publish")) return { id: "published" };
  throw Error(`Unexpected test URL ${url.pathname}`);
}
const payload = () => ({ accountID: "123", caption: "테스트", imageBase64: "/9j/AA==", requestID: crypto.randomUUID() });

test("protected routes reject missing/wrong app and installation credentials", async () => {
  const { call } = setup();
  assert.equal((await call("/account", "GET", undefined, "a".repeat(64), "wrong")).status, 401);
  assert.equal((await call("/account", "GET", undefined, "bad")).status, 401);
  assert.deepEqual(await (await call("/account")).json(), { connected: false, account: null, connectionMode: "oauth" });
});
test("OAuth starts with required permissions and unique state, rejects fabricated callback", async () => {
  const { call } = setup();
  const start = await (await call("/oauth/start", "POST")).json();
  const auth = new URL(start.authorizationURL);
  assert.equal(auth.searchParams.get("redirect_uri"), "https://test.example/oauth/callback");
  assert.equal(auth.searchParams.get("scope"), "instagram_business_basic,instagram_business_content_publish");
  assert.equal((await call(`/oauth/callback?state=${"a".repeat(64)}.${"b".repeat(64)}&code=fake`)).status, 400);
});
test("successful callback is single-use, binds to originating installation and never returns token", async t => {
  mockMeta(t, successMeta);
  const { call } = setup();
  const { start, state, response } = await login(call);
  const callback = new URL(response.headers.get("location"));
  assert.equal(callback.searchParams.get("status"), "success");
  assert.equal(callback.searchParams.get("attempt"), start.attempt);
  assert.equal((await call(`/oauth/callback?code=test-code&state=${state}`)).status, 400);
  const own = await (await call("/account")).text();
  assert.equal(JSON.parse(own).account.username, "testshop");
  assert.ok(!own.includes("secret"));
  assert.equal((await (await call("/account", "GET", undefined, "b".repeat(64))).json()).connected, false);
});
test("denial and expired state do not establish a connection", async () => {
  const { call, objects } = setup();
  const start = await (await call("/oauth/start", "POST")).json();
  const state = new URL(start.authorizationURL).searchParams.get("state");
  const denied = await call(`/oauth/callback?error=access_denied&state=${state}`);
  assert.equal(new URL(denied.headers.get("location")).searchParams.get("status"), "denied");
  await call("/oauth/start", "POST");
  const object = [...objects.values()][0];
  const pending = await object.ctx.storage.get("pending");
  await object.ctx.storage.put("pending", { ...pending, expires: 0 });
  assert.equal((await call(`/oauth/callback?code=test-code&state=${pending.state}`)).status, 400);
  assert.equal((await (await call("/account")).json()).connected, false);
});
test("token exchange failure is explicit and does not expose secrets", async t => {
  mockMeta(t, () => ({ error: { code: 190, message: "secret value" } }));
  const { call } = setup();
  const { response } = await login(call);
  assert.equal(new URL(response.headers.get("location")).searchParams.get("status"), "failed");
  assert.equal((await (await call("/account")).json()).connected, false);
});
test("publish checks account ownership and deduplicates successful requests", async t => {
  let publications = 0;
  mockMeta(t, url => { if (url.pathname.endsWith("/media_publish")) publications++; return successMeta(url); });
  const { call } = setup(); await login(call);
  const body = payload();
  assert.equal((await call("/publish", "POST", { ...body, accountID: "other" })).status, 409);
  assert.equal((await call("/publish", "POST", body)).status, 200);
  assert.equal((await call("/publish", "POST", body)).status, 200);
  assert.equal(publications, 1);
  assert.equal((await call("/publish", "POST", { ...body, caption: "changed" })).status, 409);
});
test("uncertain publish failure cannot be retried with the same request ID", async t => {
  let publications = 0;
  mockMeta(t, url => {
    if (url.pathname.endsWith("/media_publish")) { publications++; throw Error("timeout"); }
    return successMeta(url);
  });
  const { call } = setup(); await login(call);
  const body = payload();
  assert.equal((await call("/publish", "POST", body)).status, 502);
  assert.equal((await call("/publish", "POST", body)).status, 409);
  assert.equal(publications, 1);
});
test("disconnect removes server credentials and invalidates pending callbacks", async t => {
  mockMeta(t, successMeta);
  const { call, objects } = setup(); await login(call);
  const start = await (await call("/oauth/start", "POST")).json();
  await call("/disconnect", "POST");
  assert.equal((await (await call("/account")).json()).connected, false);
  assert.equal(await [...objects.values()][0].ctx.storage.get("connection"), undefined);
  const state = new URL(start.authorizationURL).searchParams.get("state");
  assert.equal((await call(`/oauth/callback?state=${state}&code=test-code`)).status, 400);
});
test("near-expiry token refresh and expired connection handling", async t => {
  mockMeta(t, url => url.pathname === "/refresh_access_token" ? { access_token: "refreshed", expires_in: 5184000 } : successMeta(url));
  const { call, objects } = setup(); await login(call);
  const storage = [...objects.values()][0].ctx.storage;
  const connection = await storage.get("connection");
  await storage.put("connection", { ...connection, expires: Date.now() + 3600000, refreshed: 0 });
  await call("/account");
  assert.equal((await storage.get("connection")).token, "refreshed");
  await storage.put("connection", { ...connection, expires: 0 });
  assert.equal((await (await call("/account")).json()).connected, false);
});
