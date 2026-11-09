import test from "node:test";
import assert from "node:assert/strict";
import { createWorker } from "../src/index.js";

const APP_KEY = "test-only-common-dobby-app-key";
const OPENAI_KEY = "test-only-server-openai-key";
const LEGACY_TOKEN = "test-only-trusted-development-token";
const INSTALLATION_ID = "ab".repeat(32);
const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const PAYLOAD = { photos: [{ id: "front-1", role: "front", imageDataUrl: PNG }] };
const UPSTREAM_RESPONSE = {
  status: "completed",
  output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: JSON.stringify({
    brand: null,
    productNameWithoutBrand: "네이비 후드 집업",
    description: "네이비 색상의 후드 집업입니다.",
    reviewNotes: [],
    identification: null,
  }) }] }],
};

function request({ appKey = APP_KEY, authorization = `Bearer ${INSTALLATION_ID}`, payload = PAYLOAD } = {}) {
  const headers = new Headers({ "Content-Type": "application/json" });
  if (appKey !== null) headers.set("X-Dobby-App-Key", appKey);
  if (authorization !== null) headers.set("Authorization", authorization);
  return new Request("https://worker.example/v1/garments/autofill", {
    method: "POST", headers, body: typeof payload === "string" ? payload : JSON.stringify(payload),
  });
}

function limiter(decision = true) {
  const keys = [];
  return {
    keys,
    async limit({ key }) {
      keys.push(key);
      return { success: typeof decision === "function" ? decision(key, keys.length) : decision };
    },
  };
}

function harness(overrides = {}) {
  const upstreamCalls = [];
  const installation = limiter();
  const shared = limiter();
  const env = {
    DOBBY_APP_API_KEY: APP_KEY,
    OPENAI_API_KEY: OPENAI_KEY,
    AI_INSTALLATION_RATE_LIMITER: installation,
    AI_SHARED_RATE_LIMITER: shared,
    ...overrides,
  };
  const worker = createWorker({ fetchImpl: async (url, init) => {
    upstreamCalls.push({ url: String(url), init });
    return Response.json(UPSTREAM_RESPONSE);
  } });
  return { worker, env, installation, shared, upstreamCalls };
}

async function assertRejected(h, req, status, code) {
  const response = await h.worker.fetch(req, h.env);
  assert.equal(response.status, status);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Retry-After"), status === 429 ? "60" : null);
  const text = await response.text();
  const payload = JSON.parse(text);
  assert.equal(payload.error.code, code);
  assert.equal(typeof payload.error.message, "string");
  assert.equal(typeof payload.requestId, "string");
  for (const value of [APP_KEY, OPENAI_KEY, LEGACY_TOKEN, INSTALLATION_ID, PNG, "private-binding-error"]) {
    assert.equal(text.includes(value), false);
  }
  assert.equal(req.bodyUsed, false, "rejected requests must not read photos");
  assert.equal(h.upstreamCalls.length, 0);
}

test("common app credentials call OpenAI after both server checks without a legacy token", async () => {
  const h = harness();
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).productName, "네이비 후드 집업");
  assert.deepEqual(h.installation.keys, [`garment-autofill:installation:${INSTALLATION_ID}`]);
  assert.deepEqual(h.shared.keys, ["garment-autofill:app"]);
  assert.equal(h.upstreamCalls.length, 1);
  const outgoing = new Headers(h.upstreamCalls[0].init.headers);
  assert.equal(outgoing.get("Authorization"), `Bearer ${OPENAI_KEY}`);
  assert.equal(outgoing.has("X-Dobby-App-Key"), false);
  assert.equal(h.upstreamCalls[0].init.body.includes(INSTALLATION_ID), false);
  assert.equal(h.upstreamCalls[0].init.body.includes(APP_KEY), false);
});

test("invalid app credentials reject before rate checks, photo reads, or upstream", async (t) => {
  const invalidRequests = [
    ["wrong app key", { appKey: "wrong-common-key" }],
    ["empty app key", { appKey: "" }],
    ["oversized app key", { appKey: "a".repeat(1025) }],
    ["missing bearer", { authorization: null }],
    ["wrong scheme", { authorization: `Basic ${INSTALLATION_ID}` }],
    ["short installation ID", { authorization: `Bearer ${"a".repeat(63)}` }],
    ["long installation ID", { authorization: `Bearer ${"a".repeat(65)}` }],
    ["uppercase installation ID", { authorization: `Bearer ${"AB".repeat(32)}` }],
    ["nonhex installation ID", { authorization: `Bearer ${"z".repeat(64)}` }],
    ["multiple bearer values", { authorization: `Bearer ${INSTALLATION_ID}, Bearer ${INSTALLATION_ID}` }],
    ["arbitrary development token", { authorization: `Bearer ${LEGACY_TOKEN}` }],
  ];
  for (const [name, options] of invalidRequests) {
    await t.test(name, async () => {
      const h = harness({ DRAFT_API_TOKEN: LEGACY_TOKEN });
      await assertRejected(h, request({ ...options, payload: "invalid-json" }), 401, "unauthorized");
      assert.deepEqual(h.installation.keys, []);
      assert.deepEqual(h.shared.keys, []);
    });
  }
});

test("an explicit app header cannot downgrade to valid legacy credentials", async (t) => {
  for (const appKey of ["wrong-common-key", "", APP_KEY]) {
    await t.test(appKey || "empty header", async () => {
      const h = harness({ DRAFT_API_TOKEN: LEGACY_TOKEN });
      await assertRejected(h, request({ appKey, authorization: `Bearer ${LEGACY_TOKEN}` }), 401, "unauthorized");
      assert.deepEqual(h.installation.keys, []);
      assert.deepEqual(h.shared.keys, []);
    });
  }
});

test("legacy clients remain supported without app secrets or usage bindings", async () => {
  const h = harness({
    DRAFT_API_TOKEN: LEGACY_TOKEN,
    DOBBY_APP_API_KEY: undefined,
    AI_INSTALLATION_RATE_LIMITER: undefined,
    AI_SHARED_RATE_LIMITER: undefined,
  });
  const response = await h.worker.fetch(request({ appKey: null, authorization: `Bearer ${LEGACY_TOKEN}` }), h.env);
  assert.equal(response.status, 200);
  assert.equal(h.upstreamCalls.length, 1);
  assert.deepEqual(h.installation.keys, []);
  assert.deepEqual(h.shared.keys, []);
});

test("installation bearer alone does not authenticate as a legacy token", async () => {
  const h = harness({ DRAFT_API_TOKEN: LEGACY_TOKEN });
  await assertRejected(h, request({ appKey: null }), 401, "unauthorized");
  assert.deepEqual(h.installation.keys, []);
  assert.deepEqual(h.shared.keys, []);
});

test("missing app configuration fails closed before either quota check", async (t) => {
  const missingConfigurations = [
    ["app key", { DOBBY_APP_API_KEY: undefined }],
    ["OpenAI key", { OPENAI_API_KEY: undefined }],
    ["installation binding", { AI_INSTALLATION_RATE_LIMITER: undefined }],
    ["shared binding", { AI_SHARED_RATE_LIMITER: undefined }],
    ["malformed installation binding", { AI_INSTALLATION_RATE_LIMITER: {} }],
    ["malformed shared binding", { AI_SHARED_RATE_LIMITER: { limit: true } }],
  ];
  for (const [name, configuration] of missingConfigurations) {
    await t.test(name, async () => {
      const h = harness(configuration);
      await assertRejected(h, request(), 503, "service_not_configured");
      assert.deepEqual(h.installation.keys, []);
      assert.deepEqual(h.shared.keys, []);
    });
  }
});

test("exhausted installation quota returns a retry interval without consuming shared quota", async () => {
  const h = harness({ AI_INSTALLATION_RATE_LIMITER: limiter(false) });
  await assertRejected(h, request(), 429, "rate_limited");
  assert.equal(h.env.AI_INSTALLATION_RATE_LIMITER.keys.length, 1);
  assert.deepEqual(h.shared.keys, []);
});

test("shared quota rejects requests even when an installation is allowed", async () => {
  const h = harness({ AI_SHARED_RATE_LIMITER: limiter(false) });
  await assertRejected(h, request(), 429, "rate_limited");
  assert.equal(h.installation.keys.length, 1);
  assert.equal(h.env.AI_SHARED_RATE_LIMITER.keys.length, 1);
});

test("binding exceptions and invalid responses fail closed without leaking provider errors", async (t) => {
  for (const bindingName of ["AI_INSTALLATION_RATE_LIMITER", "AI_SHARED_RATE_LIMITER"]) {
    for (const result of [undefined, null, {}, { success: "true" }, { success: 1 }, "throw"]) {
      await t.test(`${bindingName}: ${JSON.stringify(result)}`, async () => {
        const h = harness({ [bindingName]: { async limit() {
          if (result === "throw") throw new Error(`private-binding-error ${APP_KEY}`);
          return result;
        } } });
        await assertRejected(h, request(), 503, "usage_protection_unavailable");
        if (bindingName === "AI_INSTALLATION_RATE_LIMITER") assert.deepEqual(h.shared.keys, []);
      });
    }
  }
});

test("rotating installation IDs still uses one shared server quota key", async () => {
  const shared = limiter((key, count) => count <= 2);
  const h = harness({ AI_SHARED_RATE_LIMITER: shared });
  for (const digit of ["a", "b"]) {
    const response = await h.worker.fetch(request({ authorization: `Bearer ${digit.repeat(64)}` }), h.env);
    assert.equal(response.status, 200);
  }
  const rejected = request({ authorization: `Bearer ${"c".repeat(64)}` });
  const response = await h.worker.fetch(rejected, h.env);
  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, "rate_limited");
  assert.equal(response.headers.get("Retry-After"), "60");
  assert.equal(rejected.bodyUsed, false);
  assert.equal(h.upstreamCalls.length, 2);
  assert.equal(new Set(shared.keys).size, 1);
  assert.equal(new Set(h.installation.keys).size, 3);
});
