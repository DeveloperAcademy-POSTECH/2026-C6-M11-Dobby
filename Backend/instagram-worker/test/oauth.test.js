import test from "node:test";
import assert from "node:assert/strict";
import worker, { InstagramAccountConnections, InstagramConnection } from "../src/index.js";

function setup() {
  const objects = new Map(), accountObjects = new Map(), media = new Map();
  const createStorage = () => {
    const data = new Map();
    return { async get(k) { return structuredClone(data.get(k)); }, async put(k, v) { data.set(k, structuredClone(v)); }, async delete(k) { data.delete(k); }, async deleteAll() { data.clear(); } };
  };
  const env = {
    PUBLIC_BASE_URL: "https://test.example", INSTAGRAM_API_VERSION: "v25.0",
    DOBBY_APP_API_KEY: "app-secret", INSTAGRAM_APP_ID: "instagram-app", INSTAGRAM_APP_SECRET: "instagram-secret",
    INSTAGRAM_MEDIA: { async put(k, v) { media.set(k, v); }, async get(k) { return media.get(k); }, async delete(k) { media.delete(k); } },
    INSTAGRAM_CONNECTIONS: {
      idFromName: name => name,
      idFromString: id => id,
      get(id) {
        if (!objects.has(id)) {
          objects.set(id, new InstagramConnection({ storage: createStorage() }, env));
        }
        return objects.get(id);
      }
    },
    INSTAGRAM_ACCOUNT_CONNECTIONS: {
      idFromName: name => name,
      idFromString: id => id,
      get(id) {
        if (!accountObjects.has(id)) {
          accountObjects.set(id, new InstagramAccountConnections({ storage: createStorage() }, env));
        }
        return accountObjects.get(id);
      }
    }
  };
  const call = (path, method = "GET", body, owner = "a".repeat(64), key = "app-secret") => worker.fetch(new Request(`https://test.example${path}`, {
    method, headers: { "X-Dobby-App-Key": key, Authorization: `Bearer ${owner}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body)
  }), env);
  return { env, call, objects, accountObjects, media };
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
  if (url.host === "api.instagram.com") return { data: [{ access_token: "short-secret", user_id: "123", permissions: "instagram_business_basic,instagram_business_content_publish" }] };
  if (url.pathname === "/access_token") return { access_token: "long-secret", expires_in: 5184000 };
  if (url.pathname.endsWith("/me")) return { user_id: "123", username: "testshop", account_type: "BUSINESS",
    profile_picture_url: "https://cdn.example/profile.jpg" };
  if (url.pathname.endsWith("/media")) return { id: "container" };
  if (url.pathname.endsWith("/container")) return { status_code: "FINISHED" };
  if (url.pathname.endsWith("/media_publish")) return { id: "published" };
  throw Error(`Unexpected test URL ${url.pathname}`);
}
function base64URL(value) {
  return Buffer.from(value).toString("base64url");
}
async function signedRequest(userID = "123", secret = "instagram-secret") {
  const payload = base64URL(JSON.stringify({ algorithm: "HMAC-SHA256", user_id: userID, issued_at: Math.floor(Date.now() / 1000) }));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
  return `${Buffer.from(signature).toString("base64url")}.${payload}`;
}
async function metaCallback(env, path, signed) {
  return worker.fetch(new Request(`https://test.example${path}`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ signed_request: signed })
  }), env);
}
const payload = () => ({ accountID: "123", caption: "테스트", imageBase64: "/9j/AA==", requestID: crypto.randomUUID() });
const carouselPayload = count => ({
  accountID: "123", caption: "캐러셀 테스트",
  imagesBase64: Array.from({ length: count }, (_, index) => index % 2 ? "/9j/AQ==" : "/9j/AA=="),
  requestID: crypto.randomUUID()
});

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
  assert.equal(auth.searchParams.get("enable_fb_login"), "0");
  assert.equal(auth.searchParams.get("force_reauth"), "true");
  assert.equal(auth.searchParams.has("force_authentication"), false);
  assert.equal((await call(`/oauth/callback?state=${"a".repeat(64)}.${"b".repeat(64)}&code=fake`)).status, 400);
});
test("successful callback is single-use, binds to originating installation and never returns token", async t => {
  const logs = [];
  t.mock.method(console, "log", message => logs.push(String(message)));
  mockMeta(t, successMeta);
  const { call } = setup();
  const { start, state, response } = await login(call);
  const callback = new URL(response.headers.get("location"));
  assert.equal(callback.searchParams.get("status"), "success");
  assert.equal(callback.searchParams.get("attempt"), start.attempt);
  assert.equal((await call(`/oauth/callback?code=test-code&state=${state}`)).status, 400);
  const own = await (await call("/account")).text();
  assert.equal(JSON.parse(own).account.username, "testshop");
  assert.equal(JSON.parse(own).account.profilePictureURL, "https://cdn.example/profile.jpg");
  assert.ok(!own.includes("secret"));
  assert.equal((await (await call("/account", "GET", undefined, "b".repeat(64))).json()).connected, false);
  const oauthLogs = logs.filter(message => message.includes('"event":"instagram_oauth"'));
  for (const stage of ["oauth_start", "oauth_callback_received", "short_token_exchange",
    "long_token_exchange", "account_fetch", "connection_saved", "oauth_completed"]) {
    assert.ok(oauthLogs.some(message => message.includes(`"stage":"${stage}"`)));
  }
  assert.ok(!oauthLogs.join("\n").includes("short-secret"));
  assert.ok(!oauthLogs.join("\n").includes("long-secret"));
  assert.ok(!oauthLogs.join("\n").includes("test-code"));
});
test("OAuth accepts top-level short-token responses without exposing the token", async t => {
  const logs = [];
  t.mock.method(console, "log", message => logs.push(String(message)));
  mockMeta(t, url => {
    if (url.host === "api.instagram.com") {
      return { access_token: "top-level-secret", user_id: "123" };
    }
    return successMeta(url);
  });
  const { call } = setup();
  const { response } = await login(call);
  assert.equal(new URL(response.headers.get("location")).searchParams.get("status"), "success");
  assert.equal((await (await call("/account")).json()).connected, true);
  const diagnostic = logs.find(message => message.includes('"event":"instagram_oauth_token_diagnostic"'));
  assert.ok(diagnostic.includes('"outcome":"ok"'));
  assert.ok(diagnostic.includes('"responseShape":"top_level"'));
  assert.ok(!logs.join("\n").includes("top-level-secret"));
});
test("OAuth rejects empty, duplicate or malformed short-token envelopes", async t => {
  const logs = [];
  t.mock.method(console, "error", message => logs.push(String(message)));
  const invalidResponses = [
    { data: [] },
    { data: [{ access_token: "first", user_id: "123" }, { access_token: "second", user_id: "456" }] },
    { data: [{ access_token: "short-secret", user_id: "invalid" }] },
    { access_token: "top-level-secret", user_id: "invalid" }
  ];
  mockMeta(t, url => {
    if (url.host === "api.instagram.com") return invalidResponses.shift();
    return successMeta(url);
  });
  const { call } = setup();
  for (let index = 0; index < 4; index++) {
    const { response } = await login(call);
    assert.equal(new URL(response.headers.get("location")).searchParams.get("status"), "failed");
    assert.equal((await (await call("/account")).json()).connected, false);
  }
  const diagnostics = logs.filter(message => message.includes('"event":"instagram_oauth_token_diagnostic"'));
  assert.ok(diagnostics.some(message => message.includes('"responseShape":"data_envelope"')));
  assert.ok(diagnostics.some(message => message.includes('"responseShape":"top_level"')));
  assert.ok(diagnostics.every(message => message.includes('"reason":"invalid_response_shape"')));
  assert.ok(!diagnostics.join("\n").includes("short-secret"));
  assert.ok(!diagnostics.join("\n").includes("top-level-secret"));
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
  const logs = [];
  t.mock.method(console, "error", message => logs.push(String(message)));
  mockMeta(t, () => ({
    error_type: "OAuthException", code: 400,
    error_message: "The authorization code was already used and contains secret value"
  }));
  const { call } = setup();
  const { response } = await login(call);
  assert.equal(new URL(response.headers.get("location")).searchParams.get("status"), "failed");
  assert.equal((await (await call("/account")).json()).connected, false);
  const diagnostic = logs.find(message => message.includes('"event":"instagram_oauth_token_diagnostic"'));
  assert.ok(diagnostic.includes('"metaCode":400'));
  assert.ok(diagnostic.includes('"metaType":"OAuthException"'));
  assert.ok(diagnostic.includes('"reason":"code_invalid_or_used"'));
  assert.ok(!diagnostic.includes("secret value"));
  assert.ok(!diagnostic.includes("authorization code"));
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
test("multiple images create ordered carousel children and publish only the parent", async t => {
  const children = [], imageURLs = [];
  let parentCreated = false, publishedCreationID;
  mockMeta(t, (url, options) => {
    if (!url.pathname.endsWith("/media") && !url.pathname.endsWith("/media_publish")
        && !url.pathname.includes("/child-") && !url.pathname.endsWith("/carousel")) {
      return successMeta(url);
    }
    const parameters = new URLSearchParams(options?.body);
    if (url.pathname.endsWith("/media_publish")) {
      publishedCreationID = parameters.get("creation_id");
      return { id: "published-carousel" };
    }
    if (url.pathname.includes("/child-") || url.pathname.endsWith("/carousel")) {
      return { status_code: "FINISHED" };
    }
    if (parameters.get("media_type") === "CAROUSEL") {
      parentCreated = true;
      assert.equal(parameters.get("children"), "child-1,child-2");
      assert.equal(parameters.get("caption"), "캐러셀 테스트");
      return { id: "carousel" };
    }
    const id = `child-${children.length + 1}`;
    children.push(id);
    imageURLs.push(parameters.get("image_url"));
    assert.equal(parameters.get("is_carousel_item"), "true");
    assert.equal(parameters.has("caption"), false);
    return { id };
  });
  const { call, media } = setup(); await login(call);
  const response = await call("/publish", "POST", carouselPayload(2));
  assert.equal(response.status, 200);
  assert.deepEqual(children, ["child-1", "child-2"]);
  assert.equal(new Set(imageURLs).size, 2);
  assert.equal(media.size, 0);
  assert.equal(parentCreated, true);
  assert.equal(publishedCreationID, "carousel");
});
test("child containers are created five at a time without changing image order", async t => {
  let activeCreations = 0, maximumActiveCreations = 0, completedCreations = 0, nextChild = 0;
  let secondBatchStartedEarly = false, parentChildren;
  mockMeta(t, async (url, options) => {
    if (!url.pathname.endsWith("/media") && !url.pathname.endsWith("/media_publish")
        && !url.pathname.includes("/child-") && !url.pathname.endsWith("/carousel")) {
      return successMeta(url);
    }
    const parameters = new URLSearchParams(options?.body);
    if (url.pathname.endsWith("/media_publish")) return { id: "published-carousel" };
    if (url.pathname.includes("/child-") || url.pathname.endsWith("/carousel")) {
      return { status_code: "FINISHED" };
    }
    if (parameters.get("media_type") === "CAROUSEL") {
      parentChildren = parameters.get("children");
      return { id: "carousel" };
    }
    const childIndex = ++nextChild;
    if (childIndex > 5 && completedCreations < 5) secondBatchStartedEarly = true;
    activeCreations++;
    maximumActiveCreations = Math.max(maximumActiveCreations, activeCreations);
    await new Promise(resolve => setTimeout(resolve, 5));
    activeCreations--;
    completedCreations++;
    return { id: `child-${childIndex}` };
  });
  const { call } = setup(); await login(call);
  assert.equal((await call("/publish", "POST", carouselPayload(10))).status, 200);
  assert.equal(maximumActiveCreations, 5);
  assert.equal(secondBatchStartedEarly, false);
  assert.equal(parentChildren, Array.from({ length: 10 }, (_, index) => `child-${index + 1}`).join(","));
});
test("container readiness is checked again after two seconds", async t => {
  const delays = [];
  let statusChecks = 0;
  t.mock.method(globalThis, "setTimeout", (operation, delay) => {
    delays.push(delay);
    operation();
    return 0;
  });
  mockMeta(t, url => {
    if (url.pathname.endsWith("/container")) {
      statusChecks++;
      return { status_code: statusChecks === 1 ? "IN_PROGRESS" : "FINISHED" };
    }
    return successMeta(url);
  });
  const { call } = setup(); await login(call);
  assert.equal((await call("/publish", "POST", payload())).status, 200);
  assert.deepEqual(delays, [2000]);
  assert.equal(statusChecks, 2);
});
test("failed child creation stops before the next batch and publication", async t => {
  let childCreations = 0, parentCreations = 0, publications = 0;
  mockMeta(t, async (url, options) => {
    if (!url.pathname.endsWith("/media") && !url.pathname.endsWith("/media_publish")) {
      return successMeta(url);
    }
    if (url.pathname.endsWith("/media_publish")) {
      publications++;
      return { id: "unexpected" };
    }
    const parameters = new URLSearchParams(options?.body);
    if (parameters.get("media_type") === "CAROUSEL") {
      parentCreations++;
      return { id: "unexpected" };
    }
    const childIndex = ++childCreations;
    if (childIndex === 3) return { error: { code: 2, message: "temporary failure" } };
    await new Promise(resolve => setTimeout(resolve, 5));
    return { id: `child-${childIndex}` };
  });
  const { call } = setup(); await login(call);
  assert.equal((await call("/publish", "POST", carouselPayload(10))).status, 502);
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(childCreations, 5);
  assert.equal(parentCreations, 0);
  assert.equal(publications, 0);
});
test("carousel validation rejects too many or invalid images before creating media", async t => {
  let mediaCreations = 0;
  mockMeta(t, url => {
    if (url.pathname.endsWith("/media")) mediaCreations++;
    return successMeta(url);
  });
  const { call } = setup(); await login(call);
  assert.equal((await call("/publish", "POST", carouselPayload(11))).status, 400);
  const invalid = carouselPayload(2); invalid.imagesBase64[1] = "bad";
  assert.equal((await call("/publish", "POST", invalid)).status, 400);
  assert.equal(mediaCreations, 0);
});
test("failed carousel child processing prevents parent creation and publication", async t => {
  let childCount = 0, parentCreations = 0, publications = 0;
  mockMeta(t, (url, options) => {
    if (!url.pathname.endsWith("/media") && !url.pathname.endsWith("/media_publish")
        && !url.pathname.includes("/child-")) return successMeta(url);
    if (url.pathname.endsWith("/media_publish")) { publications++; return { id: "unexpected" }; }
    if (url.pathname.includes("/child-")) {
      return { status_code: url.pathname.endsWith("/child-2") ? "ERROR" : "FINISHED" };
    }
    const parameters = new URLSearchParams(options?.body);
    if (parameters.get("media_type") === "CAROUSEL") { parentCreations++; return { id: "carousel" }; }
    childCount++;
    return { id: `child-${childCount}` };
  });
  const { call } = setup(); await login(call);
  assert.equal((await call("/publish", "POST", carouselPayload(2))).status, 409);
  assert.equal(childCount, 2);
  assert.equal(parentCreations, 0);
  assert.equal(publications, 0);
});
test("carousel image order is part of duplicate request protection", async t => {
  let childCount = 0;
  mockMeta(t, (url, options) => {
    if (!url.pathname.endsWith("/media") && !url.pathname.endsWith("/media_publish")
        && !url.pathname.includes("/child-") && !url.pathname.endsWith("/carousel")) {
      return successMeta(url);
    }
    if (url.pathname.endsWith("/media_publish")) return { id: "published" };
    if (url.pathname.includes("/child-") || url.pathname.endsWith("/carousel")) return { status_code: "FINISHED" };
    const parameters = new URLSearchParams(options?.body);
    if (parameters.get("media_type") === "CAROUSEL") return { id: "carousel" };
    childCount++;
    return { id: `child-${childCount}` };
  });
  const { call } = setup(); await login(call);
  const body = carouselPayload(2);
  assert.equal((await call("/publish", "POST", body)).status, 200);
  assert.equal((await call("/publish", "POST", { ...body, imagesBase64: [...body.imagesBase64].reverse() })).status, 409);
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
test("Meta deauthorization verifies the signature and removes every installation for the user", async t => {
  mockMeta(t, successMeta);
  const { call, env, objects } = setup();
  await login(call);
  await login((path, method = "GET", body) => call(path, method, body, "b".repeat(64)));
  const forged = await metaCallback(env, "/oauth/deauthorize", await signedRequest("123", "wrong-secret"));
  assert.equal(forged.status, 401);
  for (const object of objects.values()) assert.ok(await object.ctx.storage.get("connection"));
  const response = await metaCallback(env, "/oauth/deauthorize", await signedRequest());
  assert.equal(response.status, 200);
  for (const object of objects.values()) assert.equal(await object.ctx.storage.get("connection"), undefined);
});
test("Meta data deletion is idempotent and exposes a temporary status page", async t => {
  mockMeta(t, successMeta);
  const { call, env, objects } = setup();
  await login(call);
  const signed = await signedRequest();
  const first = await metaCallback(env, "/oauth/data-deletion", signed);
  assert.equal(first.status, 200);
  const firstBody = await first.json();
  assert.match(firstBody.confirmation_code, /^[a-f0-9]{64}$/);
  assert.equal(firstBody.url, `https://test.example/data-deletion/status/${firstBody.confirmation_code}`);
  const secondBody = await (await metaCallback(env, "/oauth/data-deletion", signed)).json();
  assert.equal(secondBody.confirmation_code, firstBody.confirmation_code);
  assert.equal((await worker.fetch(new Request(firstBody.url), env)).status, 200);
  assert.equal((await worker.fetch(new Request(`https://test.example/data-deletion/status/${"f".repeat(64)}`), env)).status, 404);
  for (const object of objects.values()) assert.equal(await object.ctx.storage.get("connection"), undefined);
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
