import { unmatchedDiscoveryResponse } from "./helpers/native-discovery.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWorker } from "../src/index.js";

const MiB = 1024 * 1024;
const TEST_TOKEN = "test-only-draft-token";
const TEST_KEY = "test-only-openai-key";
const ENV = { DRAFT_API_TOKEN: TEST_TOKEN, OPENAI_API_KEY: TEST_KEY };
const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const DRAFT = {
  brand: { originalName: "NIKE", localizedName: "나이키" },
  productNameWithoutBrand: "블랙·레드 배색 집업 재킷",
  description: "블랙 바탕에 레드 배색이 보이는 집업 재킷입니다.",
  reviewNotes: ["하자·오염 상태 실물 확인 필요"],
};

function photo(overrides = {}) {
  return { id: "front-1", role: "front", imageDataUrl: PNG, ...overrides };
}

function body(photos = [photo()]) {
  return { photos };
}

function request(payload = body(), options = {}) {
  const headers = new Headers({
    "Content-Type": "application/json",
    Authorization: `Bearer ${TEST_TOKEN}`,
    ...options.headers,
  });
  return new Request("https://worker.example/v1/garments/autofill", {
    method: "POST",
    headers,
    body: typeof payload === "string" ? payload : JSON.stringify(payload),
  });
}

function upstream(draft = DRAFT, overrides = {}) {
  return {
    id: "resp_mock",
    status: "completed",
    output: [{
      type: "message", role: "assistant",
      content: [{ type: "output_text", text: JSON.stringify({ ...draft, identification: null }) }],
    }],
    ...overrides,
  };
}

function harness(response = upstream(), status = 200) {
  const calls = [];
  const worker = createWorker({
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), init });
      return Response.json(status === 200 && JSON.parse(init.body).text?.format?.name === "garment_brand_discovery"
        ? unmatchedDiscoveryResponse() : response, { status });
    },
  });
  return { worker, calls };
}

async function assertFailure(response, expectedStatus, forbidden = []) {
  assert.equal(response.status, expectedStatus);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const text = await response.text();
  const data = JSON.parse(text);
  assert.equal(typeof data.error?.code, "string");
  assert.equal(typeof data.error?.message, "string");
  assert.equal(typeof data.requestId, "string");
  assert.ok(data.requestId.length > 0);
  for (const secret of [TEST_TOKEN, TEST_KEY, ...forbidden]) {
    assert.equal(text.includes(secret), false, `response leaked ${secret}`);
  }
  return data;
}

// Signature-valid synthetic bytes isolate size-limit validation from image decoding.
function pngBytes(size) {
  const bytes = Buffer.alloc(size);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  return `data:image/png;base64,${bytes.toString("base64")}`;
}

test("health can be checked without secrets and never calls OpenAI", async () => {
  const { worker, calls } = harness();
  const response = await worker.fetch(new Request("https://worker.example/health"), {});
  assert.equal(response.status, 200);
  assert.equal(calls.length, 0);
  const text = await response.text();
  assert.equal(text.includes(TEST_KEY), false);
  assert.equal(text.includes(TEST_TOKEN), false);
});

test("missing server configuration fails closed before any upstream request", async (t) => {
  for (const [name, env] of [
    ["draft token", { OPENAI_API_KEY: TEST_KEY }],
    ["OpenAI key", { DRAFT_API_TOKEN: TEST_TOKEN }],
  ]) {
    await t.test(name, async () => {
      const { worker, calls } = harness();
      await assertFailure(await worker.fetch(request(), env), 503);
      assert.equal(calls.length, 0);
    });
  }
});

test("unauthorized requests do not reach OpenAI", async (t) => {
  for (const authorization of ["", "Basic test", "Bearer wrong-token"]) {
    await t.test(authorization || "missing authorization", async () => {
      const { worker, calls } = harness();
      await assertFailure(await worker.fetch(request(body(), {
        headers: { Authorization: authorization },
      }), ENV), 401);
      assert.equal(calls.length, 0);
    });
  }
});

test("a valid photo produces a draft using fixed server-owned OpenAI settings", async () => {
  const { worker, calls } = harness();
  const response = await worker.fetch(request(), ENV);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.ok(response.headers.get("X-Request-Id"));
  const text = await response.text();
  const data = JSON.parse(text);
  assert.equal(data.productName, "나이키 블랙·레드 배색 집업 재킷");
  assert.equal(data.brand, "NIKE (나이키)");
  assert.equal(data.description, DRAFT.description);
  assert.ok(data.reviewNotes.includes(DRAFT.reviewNotes[0]));
  assert.equal(text.includes(TEST_KEY), false);
  assert.equal(text.includes(TEST_TOKEN), false);
  assert.equal(text.includes(PNG), false);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, "https://api.openai.com/v1/responses");
  assert.equal(calls[0].init.method, "POST");
  const headers = new Headers(calls[0].init.headers);
  assert.equal(headers.get("Authorization"), `Bearer ${TEST_KEY}`);
  const sent = JSON.parse(calls[0].init.body);
  assert.equal(sent.model, "gpt-6-luna");
  assert.equal(sent.store, false);
  assert.ok(!sent.tools || sent.tools.length === 0);
  assert.equal(sent.text.format.type, "json_schema");
  assert.equal(sent.text.format.strict, true);
  assert.ok(sent.max_output_tokens > 0);
  const images = sent.input.flatMap(item => Array.isArray(item.content) ? item.content : [])
    .filter(item => item.type === "input_image");
  assert.deepEqual(images.map(image => image.image_url), [PNG]);
  assert.equal(calls[0].init.body.includes(TEST_TOKEN), false);
});

test("an omitted photo role is accepted as detail", async () => {
  const { worker, calls } = harness();
  const { role, ...withoutRole } = photo();
  const response = await worker.fetch(request(body([withoutRole])), ENV);
  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
});

test("description paragraphs survive the API response while other fields stay on one line", async () => {
  const description = "블랙 바탕에 레드 배색이 보이는 집업 재킷입니다.\n\n배색 디자인으로 캐주얼한 스타일에 포인트를 줄 수 있습니다.";
  const { worker } = harness(upstream({
    ...DRAFT,
    brand: { originalName: " NIKE\n ", localizedName: " 나이키\t" },
    productNameWithoutBrand: "블랙·레드\n배색 집업 재킷",
    description,
    reviewNotes: ["라벨\n실물 확인 필요"],
  }));
  const response = await worker.fetch(request(), ENV);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.description, description);
  assert.equal(data.productName, "나이키 블랙·레드 배색 집업 재킷");
  assert.equal(data.brand, "NIKE (나이키)");
  assert.ok(data.reviewNotes.includes("라벨 실물 확인 필요"));
});

test("description formatting removes excess spacing without losing paragraph boundaries", async () => {
  const { worker } = harness(upstream({
    ...DRAFT,
    description: "\r\n  블랙\t 바탕에\r\n레드 배색이 보입니다.  \r\n \t\r\n\r\n  소매에  작은 자국이 보입니다. \r\n",
  }));
  const response = await worker.fetch(request(), ENV);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.description, "블랙 바탕에 레드 배색이 보입니다.\n\n소매에 작은 자국이 보입니다.");
});

test("short feature-list descriptions keep each hyphen entry on its own line", async () => {
  const { worker } = harness(upstream({
    ...DRAFT,
    description: "\r\n  - 블랙\t 바탕  \r\n  배색 집업 디자인\r\n - 곡선형 레드  배색\r\n\r\n - 왼쪽  소매 작은 자국\r\n",
  }));
  const response = await worker.fetch(request(), ENV);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.description, "- 블랙 바탕 배색 집업 디자인\n- 곡선형 레드 배색\n- 왼쪽 소매 작은 자국");
  assert.equal(data.productName, "나이키 블랙·레드 배색 집업 재킷");
  assert.equal(data.brand, "NIKE (나이키)");
});

test("paragraph and feature-list descriptions retain empty, length, and control-character validation", async (t) => {
  for (const [name, description] of [
    ["blank paragraphs", " \r\n\r\n\t "],
    ["too long", `${"가".repeat(600)}\n\n${"나".repeat(600)}`],
    ["control character", "제품 특징입니다.\n\n확인\u0000필요합니다."],
    ["too long feature list", `- ${"가".repeat(600)}\n- ${"나".repeat(600)}`],
    ["feature list control character", "- 제품 특징\n- 확인\u0000필요"],
  ]) {
    await t.test(name, async () => {
      const { worker } = harness(upstream({ ...DRAFT, description }));
      const data = await assertFailure(await worker.fetch(request(), ENV), 502);
      assert.equal(data.error.code, "invalid_ai_response");
    });
  }
});

test("unknown brands remain empty and do not acquire a brand prefix", async () => {
  const { worker } = harness(upstream({ ...DRAFT, brand: null }));
  const response = await worker.fetch(request(), ENV);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.brand, null);
  assert.equal(data.productName, DRAFT.productNameWithoutBrand);
});

test("model-supplied brand prefixes are normalized without duplication", async (t) => {
  for (const prefix of ["NIKE", "나이키", "NIKE (나이키)", "NIKE 나이키"]) {
    await t.test(prefix, async () => {
      const { worker } = harness(upstream({
        ...DRAFT,
        productNameWithoutBrand: `${prefix} ${DRAFT.productNameWithoutBrand}`,
      }));
      const response = await worker.fetch(request(), ENV);
      assert.equal(response.status, 200);
      const data = await response.json();
      assert.equal(data.productName, `나이키 ${DRAFT.productNameWithoutBrand}`);
      assert.equal(data.brand, "NIKE (나이키)");
    });
  }
});

test("unidentifiable photos return a fixed 422 without exposing model notes", async () => {
  const marker = "private-unusable-photo-notes-marker";
  const { worker, calls } = harness(upstream({
    brand: null,
    productNameWithoutBrand: "",
    description: "",
    reviewNotes: [marker],
  }));
  const data = await assertFailure(await worker.fetch(request(), ENV), 422, [marker]);
  assert.equal(data.error.code, "photo_unusable");
  assert.match(data.error.message, /사진/);
  assert.equal(calls.length, 1);
});

test("partial or malformed empty drafts remain invalid AI responses", async (t) => {
  const cases = [
    ["empty name only", { ...DRAFT, productNameWithoutBrand: "" }],
    ["empty description only", { ...DRAFT, description: "" }],
    ["missing review note", { brand: null, productNameWithoutBrand: "", description: "", reviewNotes: [] }],
    ["invalid review note", { brand: null, productNameWithoutBrand: "", description: "", reviewNotes: [123] }],
  ];
  for (const [name, draft] of cases) {
    await t.test(name, async () => {
      const { worker, calls } = harness(upstream(draft));
      const data = await assertFailure(await worker.fetch(request(), ENV), 502);
      assert.equal(data.error.code, "invalid_ai_response");
      assert.equal(calls.length, 1);
    });
  }
});

test("draft fields cannot silently change type or add unrecognized fields", async (t) => {
  const cases = [
    ["numeric name", { ...DRAFT, productNameWithoutBrand: 123 }],
    ["numeric description", { ...DRAFT, description: 123 }],
    ["numeric brand", { ...DRAFT, brand: { originalName: 123, localizedName: null } }],
    ["non-array review notes", { ...DRAFT, reviewNotes: "확인 필요" }],
    ["unknown field", { ...DRAFT, price: 10000 }],
  ];
  for (const [name, draft] of cases) {
    await t.test(name, async () => {
      const { worker, calls } = harness(upstream(draft));
      await assertFailure(await worker.fetch(request(), ENV), 502);
      assert.equal(calls.length, 1);
    });
  }
});

test("environment mock flags never bypass live Worker configuration", async () => {
  const { worker, calls } = harness();
  await assertFailure(await worker.fetch(request(), {
    DRAFT_API_TOKEN: TEST_TOKEN,
    MOCK: true,
    AI_MODE: "mock",
  }), 503);
  assert.equal(calls.length, 0);
});

test("malformed or unsupported input is rejected without spending an upstream call", async (t) => {
  const cases = [
    ["malformed JSON", "{"],
    ["null body", "null"],
    ["empty photos", body([])],
    ["too many photos", body(Array.from({ length: 6 }, (_, i) => photo({ id: `photo-${i}` })))],
    ["duplicate IDs", body([photo(), photo()])],
    ["empty ID", body([photo({ id: "" })])],
    ["unknown role", body([photo({ role: "not-a-role" })])],
    ["remote URL", body([photo({ imageDataUrl: "https://example.com/photo.png" })])],
    ["unsupported GIF", body([photo({ imageDataUrl: "data:image/gif;base64,R0lGODlhAQABAIAAAAUEBA==" })])],
    ["invalid base64", body([photo({ imageDataUrl: "data:image/png;base64,%%%" })])],
    ["MIME and signature disagree", body([photo({ imageDataUrl: PNG.replace("image/png", "image/jpeg") })])],
    ["unknown photo field", body([photo({ extra: "ignored input must not become a prompt" })])],
    ["client-selected model", { ...body(), model: "some-expensive-model" }],
    ["client-selected mock mode", { ...body(), mock: true }],
  ];
  for (const [name, payload] of cases) {
    await t.test(name, async () => {
      const { worker, calls } = harness();
      await assertFailure(await worker.fetch(request(payload), ENV), 400);
      assert.equal(calls.length, 0);
    });
  }
});

test("non-JSON content type is rejected before OpenAI", async () => {
  const { worker, calls } = harness();
  const response = await worker.fetch(request(body(), {
    headers: { "Content-Type": "text/plain" },
  }), ENV);
  assert.ok([400, 415].includes(response.status));
  assert.equal(calls.length, 0);
});

test("photos at the decoded per-photo and combined limit are accepted", async () => {
  const { worker, calls } = harness();
  const dataUrl = pngBytes(2 * MiB);
  const response = await worker.fetch(request(body(Array.from({ length: 4 }, (_, i) => photo({
    id: `limit-${i}`, imageDataUrl: dataUrl,
  })))), ENV);
  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
});

test("a decoded photo exceeding its limit is rejected before OpenAI", async () => {
  const { worker, calls } = harness();
  await assertFailure(await worker.fetch(request(body([photo({ imageDataUrl: pngBytes(2 * MiB + 1) })])), ENV), 413);
  assert.equal(calls.length, 0);
});

test("a combined decoded photo payload exceeding 8 MiB is rejected", async () => {
  const { worker, calls } = harness();
  const photos = Array.from({ length: 4 }, (_, i) => photo({
    id: `combined-${i}`, imageDataUrl: pngBytes(2 * MiB),
  }));
  photos.push(photo({ id: "one-byte-over", imageDataUrl: PNG }));
  await assertFailure(await worker.fetch(request(body(photos)), ENV), 413);
  assert.equal(calls.length, 0);
});

test("oversized Content-Length is rejected before OpenAI", async () => {
  const { worker, calls } = harness();
  await assertFailure(await worker.fetch(request(body(), {
    headers: { "Content-Length": String(12 * MiB + 1) },
  }), ENV), 413);
  assert.equal(calls.length, 0);
});

test("the streamed body limit is enforced even when Content-Length understates it", async () => {
  const { worker, calls } = harness();
  let canceled = false;
  const stream = new ReadableStream({
    start(controller) {
      for (let i = 0; i < 13; i++) controller.enqueue(new Uint8Array(MiB));
    },
    cancel() { canceled = true; },
  });
  const oversized = new Request("https://worker.example/v1/garments/autofill", {
    method: "POST", body: stream, duplex: "half",
    headers: { "Content-Type": "application/json", "Content-Length": "1", Authorization: `Bearer ${TEST_TOKEN}` },
  });
  await assertFailure(await worker.fetch(oversized, ENV), 413);
  assert.equal(canceled, true);
  assert.equal(calls.length, 0);
});

test("upstream error details are sanitized and requests are never retried", async (t) => {
  for (const [status, expected] of [[400, 502], [401, 503], [403, 503], [429, 503], [500, 502]]) {
    await t.test(`OpenAI ${status}`, async () => {
      const marker = "private-upstream-error-marker";
      const { worker, calls } = harness({ error: { message: `${marker}: ${TEST_KEY}` } }, status);
      await assertFailure(await worker.fetch(request(), ENV), expected, [marker]);
      assert.equal(calls.length, 1);
    });
  }
});

test("refused, incomplete, and malformed drafts never become successful listings", async (t) => {
  const marker = "private-model-output-marker";
  const cases = [
    ["refusal", upstream(DRAFT, { output: [{ type: "message", role: "assistant", content: [{ type: "refusal", refusal: marker }] }] })],
    ["incomplete", upstream(DRAFT, { status: "incomplete", incomplete_details: { reason: marker } })],
    ["non-JSON output", upstream(DRAFT, { output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: marker }] }] })],
    ["wrong draft shape", upstream({ description: marker })],
    ["empty output", upstream(DRAFT, { output: [] })],
  ];
  for (const [name, payload] of cases) {
    await t.test(name, async () => {
      const { worker, calls } = harness(payload);
      await assertFailure(await worker.fetch(request(), ENV), 502, [marker]);
      assert.equal(calls.length, 1);
    });
  }
});

test("invalid upstream JSON is sanitized", async () => {
  const marker = "private-invalid-upstream-marker";
  const worker = createWorker({ fetchImpl: async () => new Response(marker, { status: 200 }) });
  await assertFailure(await worker.fetch(request(), ENV), 502, [marker]);
});

test("network errors are sanitized without automatic retry", async () => {
  const marker = "private-network-failure-marker";
  let calls = 0;
  const worker = createWorker({ fetchImpl: async () => {
    calls++;
    throw new Error(`${marker}: ${TEST_KEY}`);
  } });
  await assertFailure(await worker.fetch(request(), ENV), 502, [marker]);
  assert.equal(calls, 1);
});

test("an upstream timeout aborts the request and returns a sanitized 504", async () => {
  let aborted = false;
  const worker = createWorker({ timeoutMs: 5, fetchImpl: async (_url, init) => new Promise((_resolve, reject) => {
    init.signal.addEventListener("abort", () => {
      aborted = true;
      reject(new DOMException("test-only-timeout-detail", "AbortError"));
    }, { once: true });
  }) });
  await assertFailure(await worker.fetch(request(), ENV), 504, ["test-only-timeout-detail"]);
  assert.equal(aborted, true);
});
