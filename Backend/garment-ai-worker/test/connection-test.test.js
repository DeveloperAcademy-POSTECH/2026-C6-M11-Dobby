import test, { after, afterEach } from "node:test";
import assert from "node:assert/strict";

// Test files run in isolated Node processes. Install the guard before import so
// even a regression cannot send photos or credentials to OpenAI from this suite.
const originalFetch = globalThis.fetch;
let networkCalls = 0;
globalThis.fetch = async () => {
  networkCalls += 1;
  throw new Error("Network access is forbidden in connection-test Worker tests.");
};
const { default: worker } = await import("../src/connection-test.js");
after(() => { globalThis.fetch = originalFetch; });
afterEach(() => { assert.equal(networkCalls, 0, "the connection-test Worker attempted network access"); });

const TOKEN = "private-connection-test-token";
const PUBLIC_LOCAL_TOKEN = "local-dobby-demo-token";
const EXISTING_OPENAI_KEY = "private-existing-openai-key-must-not-be-used";
const ENV = { DRAFT_API_TOKEN: TOKEN, OPENAI_API_KEY: EXISTING_OPENAI_KEY };
const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const PHOTO = { id: "cloud-front", role: "front", imageDataUrl: PNG };
const ORIGIN = "https://dobby-garment-ai-dev.example.workers.dev";

function request({ payload = { photos: [PHOTO] }, token = TOKEN } = {}) {
  return new Request(`${ORIGIN}/v1/garments/autofill`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(payload),
  });
}

async function readResponse(response, status) {
  assert.equal(response.status, status);
  assert.equal(response.headers.get("X-Dobby-AI-Mode"), "mock");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  assert.ok(response.headers.get("X-Request-Id"));
  const text = await response.text();
  for (const forbidden of [TOKEN, EXISTING_OPENAI_KEY, PNG]) {
    assert.equal(text.includes(forbidden), false, "response exposed request data or credentials");
  }
  return JSON.parse(text);
}

test("public cloud health identifies a connection test without requiring secrets", async () => {
  const response = await worker.fetch(new Request(`${ORIGIN}/health`), {});
  const data = await readResponse(response, 200);
  assert.deepEqual(data, { service: "dobby-garment-ai", status: "ok", mode: "connection-test" });
});

test("a cloud-host photo request returns a fixed draft without an OpenAI key", async () => {
  const data = await readResponse(await worker.fetch(request(), { DRAFT_API_TOKEN: TOKEN }), 200);
  assert.deepEqual(Object.keys(data).sort(), ["brand", "description", "productName", "reviewNotes"]);
  assert.equal(data.productName, "연결 테스트용 의류");
  assert.equal(data.brand, null);
  assert.match(data.description, /Cloudflare 연결 확인용 모의 응답/);
  assert.match(data.description, /사진을 AI로 분석하지 않았습니다/);
  assert.ok(data.reviewNotes.some(note => /모의/.test(note) && /실제 사진 분석 결과가 아닙니다/.test(note)));
});

test("real-looking API keys and live-mode environment flags cannot activate AI", async () => {
  await readResponse(await worker.fetch(request(), {
    ...ENV,
    AI_MODE: "live",
    MOCK: false,
  }), 200);
});

test("the deployed test Worker requires a private server-side token", async (t) => {
  for (const [name, env] of [
    ["missing environment", undefined],
    ["missing token", { OPENAI_API_KEY: EXISTING_OPENAI_KEY }],
    ["empty token", { DRAFT_API_TOKEN: "" }],
    ["whitespace token", { DRAFT_API_TOKEN: "not a token" }],
    ["public local fixture configured as token", { DRAFT_API_TOKEN: PUBLIC_LOCAL_TOKEN }],
  ]) {
    await t.test(name, async () => {
      const data = await readResponse(await worker.fetch(request(), env), 503);
      assert.equal(data.error.code, "service_not_configured");
    });
  }
});

test("the public loopback token and invalid request tokens cannot access cloud drafts", async (t) => {
  for (const token of [PUBLIC_LOCAL_TOKEN, "wrong-private-token", ""]) {
    await t.test(token || "empty token", async () => {
      const data = await readResponse(await worker.fetch(request({ token }), ENV), 401);
      assert.equal(data.error.code, "unauthorized");
    });
  }
});

test("cloud connection tests preserve core photo validation and reject mode overrides", async (t) => {
  for (const [name, payload] of [
    ["no photos", { photos: [] }],
    ["invalid photo", { photos: [{ ...PHOTO, imageDataUrl: "not-an-image" }] }],
    ["unknown role", { photos: [{ ...PHOTO, role: "any" }] }],
    ["client mode override", { photos: [PHOTO], mode: "live" }],
    ["client model override", { photos: [PHOTO], model: "gpt-6-luna" }],
  ]) {
    await t.test(name, async () => {
      const data = await readResponse(await worker.fetch(request({ payload }), ENV), 400);
      assert.equal(typeof data.error.code, "string");
    });
  }
});
