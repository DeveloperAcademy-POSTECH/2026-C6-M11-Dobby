import test, { after, afterEach } from "node:test";
import assert from "node:assert/strict";

// Node's default test-file isolation keeps this guard local to this file.
// Install it before importing the entry point so a regression cannot call OpenAI.
const originalFetch = globalThis.fetch;
let networkCalls = 0;
globalThis.fetch = async () => {
  networkCalls += 1;
  throw new Error("Network access is forbidden in local mock tests.");
};
const { default: worker } = await import("../src/local-mock.js");
after(() => { globalThis.fetch = originalFetch; });
afterEach(() => { assert.equal(networkCalls, 0, "the mock entry point attempted network access"); });

const TOKEN = "local-dobby-demo-token";
const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const PHOTO = { id: "local-front", role: "front", imageDataUrl: PNG };
const REAL_LIKE_ENV = {
  OPENAI_API_KEY: "private-existing-key-must-not-be-used",
  DRAFT_API_TOKEN: "private-existing-token-must-not-be-used",
};

function request({ host = "127.0.0.1:8787", payload = { photos: [PHOTO] }, token = TOKEN, headers = {} } = {}) {
  return new Request(`http://${host}/v1/garments/autofill`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      ...headers,
    },
    body: JSON.stringify(payload),
  });
}

async function readMockResponse(response, status) {
  assert.equal(response.status, status);
  assert.equal(response.headers.get("X-Dobby-AI-Mode"), "mock");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const text = await response.text();
  for (const forbidden of [...Object.values(REAL_LIKE_ENV), PNG]) {
    assert.equal(text.includes(forbidden), false, "the mock response exposed request data or credentials");
  }
  return JSON.parse(text);
}

test("loopback health explicitly identifies the mock without secrets or network", async (t) => {
  for (const host of ["127.0.0.1:8787", "localhost:8787", "[::1]:8787"]) {
    await t.test(host, async () => {
      const response = await worker.fetch(new Request(`http://${host}/health`), {});
      const data = await readMockResponse(response, 200);
      assert.equal(data.status, "ok");
      assert.equal(data.mode, "mock");
    });
  }
});

test("valid photo requests return an explicit fixed example even if real credentials exist", async () => {
  const data = await readMockResponse(await worker.fetch(request(), REAL_LIKE_ENV), 200);
  assert.deepEqual(Object.keys(data).sort(), ["brand", "description", "productName", "reviewNotes"]);
  assert.equal(data.brand, null);
  assert.equal(typeof data.productName, "string");
  assert.match(data.description, /모의/);
  assert.match(data.description, /분석하지/);
  assert.ok(data.reviewNotes.some(note => /모의/.test(note) && /실제 사진 분석 결과가 아닙니다/.test(note)));
});

test("the mock accepts only its public local token rather than an incoming environment token", async () => {
  const response = await worker.fetch(request({ token: REAL_LIKE_ENV.DRAFT_API_TOKEN }), REAL_LIKE_ENV);
  const data = await readMockResponse(response, 401);
  assert.equal(data.error.code, "unauthorized");
});

test("the local mock keeps photo and input validation active", async (t) => {
  for (const [name, payload] of [
    ["no photos", { photos: [] }],
    ["invalid photo", { photos: [{ ...PHOTO, imageDataUrl: "not-an-image" }] }],
    ["attempted live mode override", { photos: [PHOTO], mock: false }],
  ]) {
    await t.test(name, async () => {
      const data = await readMockResponse(await worker.fetch(request({ payload }), REAL_LIKE_ENV), 400);
      assert.equal(typeof data.error.code, "string");
    });
  }
});

test("deployed and non-loopback addresses cannot expose the local mock API", async (t) => {
  for (const host of ["dobby-garment-ai.workers.dev", "192.168.0.10:8787", "example.com"]) {
    await t.test(host, async () => {
      const data = await readMockResponse(await worker.fetch(request({
        host,
        headers: { Host: "localhost:8787" },
      }), REAL_LIKE_ENV), 503);
      assert.equal(data.error.code, "local_only");
      assert.equal(typeof data.requestId, "string");
    });
  }
});
