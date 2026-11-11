import test from "node:test";
import assert from "node:assert/strict";
import { createWorker } from "../src/index.js";
import { TOP_KEYPOINTS, REFINEMENT_REGIONS, REFINEMENT_VERSION } from "../src/garment-landmarks.js";

const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const REQUEST_ID = "12345678-1234-4234-9234-123456789abc";
const APP_KEY = "test-only-landmark-app-key";
const OPENAI_KEY = "test-only-landmark-openai-key";
const INSTALLATION_ID = "ab".repeat(32);
const visible = (x = 0.5, y = 0.5) => ({ point: { x, y }, visibility: "visible" });
const hidden = (visibility = "occluded") => ({ point: null, visibility });
const resultV4 = () => {
  const value = resultV3();
  value.centerSupport = { frontNeckSeamCenter: { left: { x: 0.48, y: 0.28 }, right: { x: 0.52, y: 0.3 } },
    hem_center: { left: { x: 0.49, y: 0.87 }, right: { x: 0.51, y: 0.89 } } };
  value.frontNeckSeamCenter = { point: { x: 0.4, y: 0.4 }, visibility: "estimated" };
  value.points.hem_center = { point: { x: 0.6, y: 0.6 }, visibility: "estimated" };
  return value;
};

const lengthResult = () => {
  const v = resultV4();
  return { view: v.view, neckStyle: v.neckStyle, frontNeckSeamCenter: v.frontNeckSeamCenter,
    hem_center: v.points.hem_center, centerSupport: v.centerSupport };
};
const lengthBody = () => ({ ...body(), regions: ["upper", "hem"].map(id => ({ id, image: body().image })) });
function lengthRequest(payload = lengthBody(), headers = {}) {
  return new Request("https://worker.example/v4/garments/length-refinement", {
    method: "POST", headers: { "Content-Type": "application/json", "X-Dobby-App-Key": APP_KEY,
      Authorization: `Bearer ${INSTALLATION_ID}`, ...headers }, body: JSON.stringify(payload),
  });
}
test("length recovery asks only two centers using context and two crops", async () => {
  const h = harness({ value: lengthResult() });
  const response = await h.worker.fetch(lengthRequest(), h.env);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.refinementVersion, "outerwear-two-center-refinement-v4");
  assert.equal(data.requestId, REQUEST_ID);
  assert.equal(data.modelVersion, "luna-outerwear11-front-gap-v4");
  assert.equal(data.points, undefined);
  assert.deepEqual(data.frontNeckSeamCenter.point, { x: 0.5, y: (0.28 + 0.3) / 2 });
  assert.deepEqual(data.hem_center.point, { x: 0.5, y: 0.88 });
  const sent = JSON.parse(h.calls[0].init.body);
  assert.equal(sent.model, "gpt-6-luna");
  assert.equal(sent.store, false);
  assert.equal(sent.text.format.strict, true);
  assert.deepEqual(sent.text.format.schema.required, ["view", "neckStyle", "frontNeckSeamCenter", "hem_center", "centerSupport"]);
  assert.equal(sent.input[0].content.filter(p => p.type === "input_image").length, 3);
  assert.deepEqual(sent.input[0].content.filter(p => p.type === "input_text").slice(1).map(p => JSON.parse(p.text).targets),
    [["frontNeckSeamCenter"], ["hem_center"]]);
  assert.ok(sent.instructions.includes("전체 사진 좌표로 바꾸지 마세요"));
  assert.ok(sent.instructions.includes("두 중앙점은 독립적으로 판단"));
  assert.ok(sent.instructions.includes("원단이나 가까운 마스크 경계로 밀지 마세요"));
  assert.equal(h.calls.length, 1);
});
test("length recovery allows either center independently unavailable", async () => {
  for (const id of ["frontNeckSeamCenter", "hem_center"]) {
    const v = lengthResult(); v[id] = hidden("uncertain"); v.centerSupport[id] = null;
    const h = harness({ value: v });
    const response = await h.worker.fetch(lengthRequest(), h.env);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data[id].point, null);
    assert.equal(data[id === "hem_center" ? "frontNeckSeamCenter" : "hem_center"].visibility, "estimated");
  }
});
test("length recovery rejects other points, malformed supports and opposite faces", async () => {
  for (const mutate of [v => { v.points = {}; }, v => { delete v.hem_center; },
    v => { v.centerSupport.hem_center = null; }, v => { v.hem_center.point.x = 1; },
    v => { v.centerSupport.frontNeckSeamCenter.right.x = 0.1; }, v => { v.view = "back"; }]) {
    const value = lengthResult(); mutate(value);
    await failure(harness({ value }), lengthRequest(), 502, "invalid_ai_response");
  }
  await failure(harness({ value: resultV4() }), lengthRequest(), 502, "invalid_ai_response");
});
test("length recovery accepts exactly upper and hem and retains authentication and quotas", async () => {
  for (const mutate of [v => v.regions.pop(), v => v.regions.push({ id: "armpits", image: body().image }),
    v => { v.regions[1].id = "upper"; }, v => { v.regions[0].id = "garment"; },
    v => { v.regions[1].image.width = 0; }]) {
    const b = structuredClone(lengthBody()); mutate(b);
    const h = harness();
    await failure(h, lengthRequest(b), 400, "invalid_request");
    assert.equal(h.calls.length, 0);
  }
  const unauthorized = harness();
  await failure(unauthorized, lengthRequest(lengthBody(), { Authorization: "Bearer bad" }), 401, "unauthorized");
  assert.equal(unauthorized.calls.length, 0);
  const limited = harness({ installationAllowed: false });
  const response = await limited.worker.fetch(lengthRequest(), limited.env);
  assert.equal(response.status, 429);
  assert.equal(limited.calls.length, 0);
});

test("v4 computes independent gap midpoints in regular and detail crops", async () => {
  for (const refinement of [false, true]) {
    const h = harness({ value: resultV4() });
    const response = await h.worker.fetch(refinement ? refinementRequest(refinementBody(), {}, 4) : request(body(), { version: 4 }), h.env);
    assert.equal(response.status, 200);
    const data = await response.json(), value = refinement ? data.localResponse : data;
    assert.equal(value.modelVersion, "luna-outerwear11-front-gap-v4");
    assert.deepEqual(value.frontNeckSeamCenter, { point: { x: 0.5, y: (0.28 + 0.3) / 2 }, visibility: "estimated" });
    assert.deepEqual(value.points.hem_center, { point: { x: 0.5, y: 0.88 }, visibility: "estimated" });
    assert.deepEqual(value.centerSupport, resultV4().centerSupport);
    const sent = JSON.parse(h.calls[0].init.body);
    assert.ok(sent.instructions.includes("중앙을 추정하세요"));
    assert.ok(!sent.instructions.includes("중앙이 빈 공간이면 가상으로 연결하지 말고 null"));
    assert.equal(sent.text.format.strict, true);
    if (refinement) assert.equal(data.refinementVersion, "outerwear-front-gap-refinement-v4");
  }
});
test("v4 refuses unsupported estimates; v3 retains its old contract", async () => {
  const mutations = [v => { delete v.centerSupport; }, v => { v.centerSupport.hem_center = null; },
    v => { v.points.shoulder_left.visibility = "estimated"; }, v => { v.view = "back"; },
    v => { v.centerSupport.hem_center.left.x = 1; }, v => { v.centerSupport.hem_center.left.x = 0.7; },
    v => { v.frontNeckSeamCenter.visibility = "visible"; }];
  for (const mutate of mutations) {
    const value = resultV4(); mutate(value);
    await failure(harness({ value }), request(body(), { version: 4 }), 502, "invalid_ai_response");
  }
  const value = resultV4(); delete value.centerSupport;
  await failure(harness({ value }), request(body(), { version: 3 }), 502, "invalid_ai_response");
});
test("v4 keeps the estimated hem even when the neck is unavailable", async () => {
  const value = resultV4(); value.frontNeckSeamCenter = hidden("uncertain"); value.centerSupport.frontNeckSeamCenter = null;
  const h = harness({ value });
  const response = await h.worker.fetch(request(body(), { version: 4 }), h.env);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.frontNeckSeamCenter.point, null);
  assert.equal(data.points.hem_center.visibility, "estimated");
});
const result = () => ({
  view: "front", neckStyle: "hood_and_collar",
  points: Object.fromEntries(TOP_KEYPOINTS.map(name => [name, name.startsWith("neck_") ? hidden() : visible()])),
  backNeckSeamCenter: hidden("uncertain"),
});
const resultV2 = (view = "front") => ({
  ...result(), view,
  backNeckSeamCenter: view === "back" ? visible(0.501, 0.21) : hidden("uncertain"),
  frontNeckSeamCenter: view === "front" ? visible(0.502, 0.28) : hidden("uncertain"),
});
const body = () => ({ requestId: REQUEST_ID, category: "Jacket", image: { imageDataUrl: PNG, width: 1, height: 1 } });
const refinementBody = () => ({ ...body(), regions: Object.keys(REFINEMENT_REGIONS).map(id => ({ id, image: body().image })) });
function refinementRequest(payload = refinementBody(), headers = {}, version = 2) {
  return new Request(`https://worker.example/v${version}/garments/landmark-refinement`, {
    method: "POST", headers: { "Content-Type": "application/json", "X-Dobby-App-Key": APP_KEY,
      Authorization: `Bearer ${INSTALLATION_ID}`, ...headers }, body: JSON.stringify(payload),
  });
}
const upstream = value => ({ status: "completed", output: [{ type: "message", role: "assistant",
  content: [{ type: "output_text", text: JSON.stringify(value) }] }] });

function request(payload = body(), { method = "POST", headers = {}, version = 1 } = {}) {
  return new Request(`https://worker.example/v${version}/garments/landmarks`, {
    method, headers: { "Content-Type": "application/json", "X-Dobby-App-Key": APP_KEY,
      Authorization: `Bearer ${INSTALLATION_ID}`, ...headers },
    ...(method === "GET" ? {} : { body: typeof payload === "string" ? payload : JSON.stringify(payload) }),
  });
}

function harness({ value = result(), response, status = 200, timeoutMs = 30000, fetchImpl,
  installationAllowed = true, sharedAllowed = true, env = {} } = {}) {
  const calls = [], limits = [];
  const worker = createWorker({ timeoutMs, fetchImpl: fetchImpl ?? (async (url, init) => {
    calls.push({ url: String(url), init });
    return Response.json(response ?? upstream(value), { status });
  }) });
  return { worker, calls, limits, env: {
    DOBBY_APP_API_KEY: APP_KEY, OPENAI_API_KEY: OPENAI_KEY,
    AI_INSTALLATION_RATE_LIMITER: { async limit({ key }) { limits.push(key); return { success: installationAllowed }; } },
    AI_SHARED_RATE_LIMITER: { async limit({ key }) { limits.push(key); return { success: sharedAllowed }; } },
    ...env,
  } };
}

async function failure(h, req, status, code) {
  const response = await h.worker.fetch(req, h.env);
  assert.equal(response.status, status);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const text = await response.text();
  const data = JSON.parse(text);
  assert.equal(data.error.code, code);
  for (const forbidden of [APP_KEY, OPENAI_KEY, INSTALLATION_ID, PNG, "private-marker"]) {
    assert.equal(text.includes(forbidden), false);
  }
  return response;
}

test("refinement accepts exactly five crops and returns explicit local-coordinate provenance", async () => {
  const h = harness({ value: resultV2() });
  const response = await h.worker.fetch(refinementRequest(), h.env);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.refinementVersion, REFINEMENT_VERSION);
  assert.deepEqual(data.localResponse.points, resultV2().points);
  assert.equal(data.localResponse.requestId, REQUEST_ID);
  const outgoing = JSON.parse(h.calls[0].init.body);
  assert.equal(outgoing.model, "gpt-6-luna");
  assert.equal(outgoing.reasoning.effort, "low");
  assert.equal(outgoing.max_output_tokens, 2048);
  assert.equal(outgoing.input[0].content.filter(part => part.type === "input_image").length, 6);
  assert.equal(outgoing.text.format.schema.properties.points.required.length, 11);
  assert.ok(outgoing.instructions.includes("전체 사진 좌표로 바꾸지 마세요"));
  assert.ok(!outgoing.instructions.includes("좌표 원점은 입력 사진 전체"));
  assert.ok(outgoing.instructions.includes("가상으로 연결하지 말고 null"));
  assert.deepEqual(h.limits, [`garment-autofill:installation:${INSTALLATION_ID}`, "garment-autofill:app"]);
  assert.equal(h.calls.length, 1, "one bounded call for all five crops");
});

test("refinement rejects missing duplicate unknown and malformed crops before any upstream call", async () => {
  for (const mutate of [
    payload => payload.regions.pop(),
    payload => { payload.regions[1].id = payload.regions[0].id; },
    payload => { payload.regions[0].id = "__proto__"; },
    payload => { payload.regions[0].image.width = 0; },
    payload => { payload.regions[0].extra = true; },
    payload => { payload.extra = true; },
  ]) {
    const payload = structuredClone(refinementBody()); mutate(payload);
    const h = harness();
    await failure(h, refinementRequest(payload), 400, "invalid_request");
    assert.equal(h.calls.length, 0);
  }
});

test("refinement preserves authorization quotas and v2 front/back observation rules", async () => {
  const unauthorized = harness();
  await failure(unauthorized, refinementRequest(refinementBody(), { Authorization: "Bearer invalid" }), 401, "unauthorized");
  assert.equal(unauthorized.calls.length, 0);
  const limited = harness({ installationAllowed: false });
  const rateResponse = await limited.worker.fetch(refinementRequest(), limited.env);
  assert.equal(rateResponse.status, 429);
  assert.equal(limited.calls.length, 0);
  const wrongFace = resultV2(); wrongFace.backNeckSeamCenter = visible();
  await failure(harness({ value: wrongFace }), refinementRequest(), 502, "invalid_ai_response");
});

test("landmarks reuse app auth and aggregate quotas, and echo only the caller request ID", async () => {
  const h = harness();
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const data = await response.json();
  assert.deepEqual(data, { requestId: REQUEST_ID, schemaVersion: "outerwear-landmarks-v1",
    modelVersion: "luna-outerwear11-backseam-v1", model: "gpt-6-luna", ...result() });
  assert.notEqual(response.headers.get("X-Request-Id"), REQUEST_ID, "HTTP tracing remains server-generated");
  assert.deepEqual(h.limits, [`garment-autofill:installation:${INSTALLATION_ID}`, "garment-autofill:app"]);
  assert.equal(h.calls.length, 1);
  assert.equal(h.calls[0].url, "https://api.openai.com/v1/responses");
  const outgoing = JSON.parse(h.calls[0].init.body);
  assert.equal(outgoing.model, "gpt-6-luna");
  assert.equal(outgoing.store, false);
  assert.equal(outgoing.text.format.strict, true);
  assert.equal(outgoing.text.format.name, "outerwear_landmarks");
  assert.deepEqual(outgoing.text.format.schema.properties.points.required, TOP_KEYPOINTS);
  assert.equal(outgoing.text.format.schema.properties.points.additionalProperties, false);
  assert.equal(outgoing.tools, undefined);
  assert.equal(outgoing.input[0].content[1].image_url, PNG);
  assert.deepEqual(JSON.parse(outgoing.input[0].content[0].text), { category: "Jacket", width: 1, height: 1,
    coordinateSpace: "upright-complete-image-normalized-top-left" });
  for (const value of [REQUEST_ID, APP_KEY, INSTALLATION_ID]) assert.equal(h.calls[0].init.body.includes(value), false);
  assert.equal(new Headers(h.calls[0].init.headers).get("Authorization"), `Bearer ${OPENAI_KEY}`);
  assert.equal(new Headers(h.calls[0].init.headers).has("X-Dobby-App-Key"), false);
});

test("landmarks accept all eight AI garment categories and preserve partial/unknown observations", async () => {
  for (const category of ["Blazer", "Jacket", "Coat", "Denim Jacket", "Sports Jacket", "Hoodie", "Sweater", "Polo"]) {
    const value = result();
    value.view = "unknown";
    value.neckStyle = "unknown";
    value.points = Object.fromEntries(TOP_KEYPOINTS.map(name => [name, hidden("uncertain")]));
    value.backNeckSeamCenter = hidden("uncertain");
    const h = harness({ value });
    const response = await h.worker.fetch(request({ ...body(), category }), h.env);
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).points, value.points);
    assert.equal(h.calls.length, 1);
    const sent = JSON.parse(h.calls[0].init.body);
    assert.equal(JSON.parse(sent.input[0].content[0].text).category, category);
  }
});

test("Sweater reaches Luna unchanged through both v2 whole-image and refinement routes", async () => {
  for (const req of [request({ ...body(), category: "Sweater" }, { version: 2 }),
    refinementRequest({ ...refinementBody(), category: "Sweater" })]) {
    const value = resultV2();
    value.neckStyle = "collarless";
    const h = harness({ value });
    const response = await h.worker.fetch(req, h.env);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.deepEqual((data.localResponse ?? data).points, value.points);
    assert.equal(h.calls.length, 1);
    const sent = JSON.parse(h.calls[0].init.body);
    assert.equal(JSON.parse(sent.input[0].content[0].text).category, "Sweater");
    assert.equal(sent.text.format.schema.properties.points.required.length, 11);
  }
});

test("visible back neck seam and subpixel border coordinates survive without fabricated confidence", async () => {
  const value = result();
  value.view = "back";
  value.neckStyle = "collarless";
  value.backNeckSeamCenter = visible(0.501234567, 0.213456789);
  value.points.hem_center = visible(0, 0.999999999);
  const h = harness({ value });
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.deepEqual(data.backNeckSeamCenter, value.backNeckSeamCenter);
  assert.deepEqual(data.points.hem_center, value.points.hem_center);
  assert.equal(JSON.stringify(data).includes("confidence"), false);
});

test("front and unknown observations preserve body points while leaving the back-length start unavailable", async () => {
  for (const view of ["front", "unknown"]) {
    const value = result();
    value.view = view;
    value.backNeckSeamCenter = hidden("uncertain");
    const h = harness({ value });
    const response = await h.worker.fetch(request(), h.env);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.deepEqual(data.points, value.points);
    assert.deepEqual(data.backNeckSeamCenter, { point: null, visibility: "uncertain" });
  }
});

test("invalid request shapes, dimensions, IDs, categories and model overrides stop before OpenAI", async (t) => {
  const cases = [
    ["missing body", {}], ["missing image", { requestId: REQUEST_ID, category: "Jacket" }],
    ["non UUID", { ...body(), requestId: "private-marker" }],
    ["non outerwear", { ...body(), category: "Shirt" }],
    ["client model override", { ...body(), model: "other-model" }],
    ["client prompt override", { ...body(), instructions: "private-marker" }],
    ["client points", { ...body(), points: result().points }],
    ["extra image field", { ...body(), image: { ...body().image, crop: [0, 0, 1, 1] } }],
    ...[0, -1, 1.5, 16385, "1024", null].map(width => [String(width), { ...body(), image: { ...body().image, width } }]),
    ["missing image bytes", { ...body(), image: { width: 1, height: 1 } }],
  ];
  for (const [name, payload] of cases) await t.test(name, async () => {
    const h = harness();
    await failure(h, request(payload), 400, name === "missing image bytes" ? "invalid_photo" : "invalid_request");
    assert.equal(h.calls.length, 0);
  });
});

test("landmark auth and quota failures read no photo and make no upstream request", async (t) => {
  for (const [name, options, headers, status, code] of [
    ["bad authentication", {}, { "X-Dobby-App-Key": "wrong" }, 401, "unauthorized"],
    ["missing server key", { env: { OPENAI_API_KEY: undefined } }, {}, 503, "service_not_configured"],
    ["installation quota", { installationAllowed: false }, {}, 429, "rate_limited"],
    ["shared quota", { sharedAllowed: false }, {}, 429, "rate_limited"],
    ["missing binding", { env: { AI_SHARED_RATE_LIMITER: undefined } }, {}, 503, "service_not_configured"],
  ]) await t.test(name, async () => {
    const h = harness(options), req = request("not-json", { headers });
    const response = await failure(h, req, status, code);
    assert.equal(req.bodyUsed, false);
    assert.equal(h.calls.length, 0);
    if (status === 429) assert.equal(response.headers.get("Retry-After"), "60");
  });
});

test("landmarks share existing media/content-type limits", async () => {
  let h = harness();
  await failure(h, request(body(), { headers: { "Content-Type": "text/plain" } }), 415, "unsupported_content_type");
  assert.equal(h.calls.length, 0);
  h = harness();
  const bytes = Buffer.alloc(2 * 1024 * 1024 + 1);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  await failure(h, request({ ...body(), image: { ...body().image,
    imageDataUrl: `data:image/png;base64,${bytes.toString("base64")}` } }), 413, "photo_too_large");
  assert.equal(h.calls.length, 0);
  h = harness();
  await failure(h, request({ ...body(), image: { ...body().image, imageDataUrl: "https://untrusted.example/photo" } }),
    400, "invalid_photo");
  assert.equal(h.calls.length, 0);
});

test("malformed model coordinates, visibility and extra fields are rejected without repair", async (t) => {
  const cases = [
    ["missing landmark", value => { delete value.points.hem_center; }],
    ["unknown landmark", value => { value.points.top_length_start = visible(); }],
    ["missing back seam", value => { delete value.backNeckSeamCenter; }],
    ["visible null", value => { value.points.hem_center = { point: null, visibility: "visible" }; }],
    ["occluded coordinate", value => { value.points.hem_center = { point: { x: 0.5, y: 0.9 }, visibility: "occluded" }; }],
    ["uncertain coordinate", value => { value.backNeckSeamCenter = { point: { x: 0.5, y: 0.2 }, visibility: "uncertain" }; }],
    ["back seam out of bounds", value => { value.backNeckSeamCenter = visible(0.5, 1); }],
    ["invalid visibility", value => { value.points.hem_center.visibility = "hidden"; }],
    ["negative coordinate", value => { value.points.hem_center = visible(-0.001, 0.9); }],
    ["coordinate one", value => { value.points.hem_center = visible(0.5, 1); }],
    ["string coordinate", value => { value.points.hem_center = visible("0.5", 0.9); }],
    ["null coordinate", value => { value.points.hem_center = visible(null, 0.9); }],
    ["extra point field", value => { value.points.hem_center.point.z = 1; }],
    ["self confidence", value => { value.points.hem_center.confidence = 0.99; }],
    ["model identity override", value => { value.model = "other-model"; }],
    ["model request ID", value => { value.requestId = REQUEST_ID; }],
    ["cm output", value => { value.totalLengthCM = 80; }],
    ["invalid view", value => { value.view = "side"; }],
    ["invalid neck style", value => { value.neckStyle = "private-marker"; }],
  ];
  for (const [name, mutate] of cases) await t.test(name, async () => {
    const value = result();
    mutate(value);
    const h = harness({ value });
    await failure(h, request(), 502, "invalid_ai_response");
    assert.equal(h.calls.length, 1, "invalid model output is not automatically retried");
  });
});

test("refusals, incomplete output, nonfinite numbers and invalid JSON never produce points", async (t) => {
  const content = text => ({ status: "completed", output: [{ type: "message", role: "assistant",
    content: [{ type: "output_text", text }] }] });
  for (const [name, response] of [
    ["refusal", { status: "completed", output: [{ type: "message", role: "assistant",
      content: [{ type: "refusal", refusal: "private-marker" }] }] }],
    ["incomplete", { ...upstream(result()), status: "incomplete" }],
    ["empty", { status: "completed", output: [] }],
    ["invalid JSON", content("private-marker")],
    ["oversized", content(" ".repeat(16001))],
    ["infinity", content(JSON.stringify(result()).replace('"x":0.5', '"x":1e400'))],
  ]) await t.test(name, async () => {
    const h = harness({ response });
    await failure(h, request(), 502, "invalid_ai_response");
    assert.equal(h.calls.length, 1);
  });
});

test("landmark upstream failures and timeouts remain sanitized with no retry", async () => {
  const h = harness({ status: 429, response: { error: { message: `private-marker ${OPENAI_KEY}` } } });
  await failure(h, request(), 503, "ai_rate_limited");
  assert.equal(h.calls.length, 1);
  let aborted = false;
  const timed = harness({ timeoutMs: 5, fetchImpl: async (_url, init) => new Promise((_resolve, reject) => {
    init.signal.addEventListener("abort", () => { aborted = true;
      reject(new DOMException("private-marker", "AbortError")); }, { once: true });
  }) });
  await failure(timed, request(), 504, "ai_timeout");
  assert.equal(aborted, true);
});

test("landmark route accepts only POST", async () => {
  const h = harness();
  const response = await h.worker.fetch(request(undefined, { method: "GET" }), h.env);
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("Allow"), "POST");
  assert.equal(h.calls.length, 0);
  assert.deepEqual(h.limits, []);
});

test("v2 selects a distinct strict front/back length contract without changing input, model, auth or quota", async () => {
  const value = resultV2(), h = harness({ value });
  const response = await h.worker.fetch(request(body(), { version: 2 }), h.env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { requestId: REQUEST_ID, schemaVersion: "outerwear-landmarks-v2",
    modelVersion: "luna-outerwear11-view-length-v2", model: "gpt-6-luna", ...value });
  assert.deepEqual(h.limits, [`garment-autofill:installation:${INSTALLATION_ID}`, "garment-autofill:app"]);
  assert.equal(h.calls.length, 1);
  const sent = JSON.parse(h.calls[0].init.body);
  assert.equal(sent.model, "gpt-6-luna");
  assert.deepEqual(sent.reasoning, { effort: "low" });
  assert.equal(sent.store, false);
  assert.equal(sent.tools, undefined);
  assert.equal(sent.input[0].content[1].detail, "high");
  assert.equal(sent.input[0].content[1].image_url, PNG);
  assert.deepEqual(JSON.parse(sent.input[0].content[0].text), { category: "Jacket", width: 1, height: 1,
    coordinateSpace: "upright-complete-image-normalized-top-left" });
  const schema = sent.text.format.schema;
  assert.equal(sent.text.format.strict, true);
  assert.equal(sent.text.format.name, "outerwear_landmarks_v2");
  assert.deepEqual(schema.required, ["view", "neckStyle", "points", "backNeckSeamCenter", "frontNeckSeamCenter"]);
  assert.deepEqual(schema.properties.points.required, TOP_KEYPOINTS);
  assert.equal(schema.properties.points.additionalProperties, false);
  assert.deepEqual(schema.properties.frontNeckSeamCenter, schema.properties.backNeckSeamCenter);
  for (const value of [REQUEST_ID, APP_KEY, INSTALLATION_ID]) assert.equal(h.calls[0].init.body.includes(value), false);

  const old = harness();
  const oldResponse = await old.worker.fetch(request(), old.env);
  const oldData = await oldResponse.json(), oldSent = JSON.parse(old.calls[0].init.body);
  assert.equal(oldResponse.status, 200);
  assert.equal(oldData.schemaVersion, "outerwear-landmarks-v1");
  assert.equal(oldData.modelVersion, "luna-outerwear11-backseam-v1");
  assert.equal(Object.hasOwn(oldData, "frontNeckSeamCenter"), false);
  assert.equal(Object.hasOwn(oldSent.text.format.schema.properties, "frontNeckSeamCenter"), false);
  assert.equal(oldSent.instructions.includes("frontNeckSeamCenter"), false);
});

test("v2 front/back/unknown views preserve the same eleven body observations and only their matching length helper", async () => {
  for (const view of ["front", "back", "unknown"]) {
    const value = resultV2(view), h = harness({ value });
    const response = await h.worker.fetch(request(body(), { version: 2 }), h.env);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.deepEqual(data.points, value.points);
    assert.deepEqual(Object.keys(data.points), TOP_KEYPOINTS);
    assert.deepEqual(data.backNeckSeamCenter, value.backNeckSeamCenter);
    assert.deepEqual(data.frontNeckSeamCenter, value.frontNeckSeamCenter);
    assert.equal(JSON.stringify(data).includes("confidence"), false);
  }
});

test("v2 can abstain from an occluded matching neck seam or an open/uncertain center hem without losing other points", async () => {
  for (const view of ["front", "back"]) {
    const value = resultV2(view);
    value[view === "front" ? "frontNeckSeamCenter" : "backNeckSeamCenter"] = hidden();
    value.points.hem_center = hidden("uncertain");
    const h = harness({ value });
    const response = await h.worker.fetch(request(body(), { version: 2 }), h.env);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.deepEqual(data.points, value.points);
    assert.deepEqual(data.frontNeckSeamCenter, value.frontNeckSeamCenter);
    assert.deepEqual(data.backNeckSeamCenter, value.backNeckSeamCenter);
  }
});

test("v2 rejects front/back helper mismatches and malformed new observations rather than mixing length conventions", async (t) => {
  const cases = [
    ["front with visible back seam", value => { value.backNeckSeamCenter = visible(); }],
    ["back with visible front seam", value => { value.view = "back"; value.backNeckSeamCenter = visible(); }],
    ["unknown with visible front seam", value => { value.view = "unknown"; }],
    ["unknown with visible back seam", value => { value.view = "unknown"; value.frontNeckSeamCenter = hidden("uncertain"); value.backNeckSeamCenter = visible(); }],
    ["missing front helper", value => { delete value.frontNeckSeamCenter; }],
    ["missing back helper", value => { delete value.backNeckSeamCenter; }],
    ["visible front null", value => { value.frontNeckSeamCenter = { point: null, visibility: "visible" }; }],
    ["occluded front coordinate", value => { value.frontNeckSeamCenter.visibility = "occluded"; }],
    ["uncertain front coordinate", value => { value.frontNeckSeamCenter.visibility = "uncertain"; }],
    ["out of bounds front", value => { value.frontNeckSeamCenter = visible(0.5, 1); }],
    ["negative front", value => { value.frontNeckSeamCenter = visible(-0.01, 0.3); }],
    ["front unknown visibility", value => { value.frontNeckSeamCenter.visibility = "hidden"; }],
    ["front self confidence", value => { value.frontNeckSeamCenter.confidence = 0.99; }],
    ["front extra coordinate", value => { value.frontNeckSeamCenter.point.z = 1; }],
    ["extra top field", value => { value.schemaVersion = "outerwear-landmarks-v1"; }],
    ["missing original point", value => { delete value.points.hem_center; }],
    ["invented thirteenth body point", value => { value.points.frontNeckSeamCenter = visible(); }],
  ];
  for (const [name, mutate] of cases) await t.test(name, async () => {
    const value = resultV2();
    mutate(value);
    const h = harness({ value });
    await failure(h, request(body(), { version: 2 }), 502, "invalid_ai_response");
    assert.equal(h.calls.length, 1, "invalid structured output is never retried");
  });
});

test("v1 and v2 upstream shapes cannot be silently interchanged", async () => {
  const oldShapeOnV2 = harness({ value: result() });
  await failure(oldShapeOnV2, request(body(), { version: 2 }), 502, "invalid_ai_response");
  const newShapeOnV1 = harness({ value: resultV2() });
  await failure(newShapeOnV1, request(), 502, "invalid_ai_response");
});

test("v2 route cannot override its contract through request fields and keeps authorization and quota failures before photo reads", async (t) => {
  for (const [name, options, headers, status, code] of [
    ["wrong app key", {}, { "X-Dobby-App-Key": "wrong" }, 401, "unauthorized"],
    ["installation quota", { installationAllowed: false }, {}, 429, "rate_limited"],
    ["shared quota", { sharedAllowed: false }, {}, 429, "rate_limited"],
    ["missing binding", { env: { AI_SHARED_RATE_LIMITER: undefined } }, {}, 503, "service_not_configured"],
  ]) await t.test(name, async () => {
    const h = harness(options), req = request("not-json", { version: 2, headers });
    await failure(h, req, status, code);
    assert.equal(req.bodyUsed, false);
    assert.equal(h.calls.length, 0);
  });
  const h = harness({ value: resultV2() });
  await failure(h, request({ ...body(), version: 1 }, { version: 2 }), 400, "invalid_request");
  assert.equal(h.calls.length, 0);
  const response = await h.worker.fetch(request(undefined, { version: 2, method: "GET" }), h.env);
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("Allow"), "POST");
  assert.equal(h.calls.length, 0);
});

const resultV3 = (view = "front") => {
  const value = resultV2(view);
  delete value.backNeckSeamCenter;
  return value;
};

test("v3 whole-image and refinement ask only for the front total-length start", async () => {
  for (const refinement of [false, true]) {
    const h = harness({ value: resultV3() });
    const response = await h.worker.fetch(refinement ? refinementRequest(refinementBody(), {}, 3)
      : request(body(), { version: 3 }), h.env);
    assert.equal(response.status, 200);
    const data = await response.json();
    const value = refinement ? data.localResponse : data;
    assert.equal(value.schemaVersion, "outerwear-landmarks-v3");
    assert.equal(value.modelVersion, "luna-outerwear11-front-length-v3");
    assert.equal(value.backNeckSeamCenter, undefined);
    assert.deepEqual(value.frontNeckSeamCenter, resultV3().frontNeckSeamCenter);
    assert.equal(Object.keys(value.points).length, 11);
    const sent = JSON.parse(h.calls[0].init.body);
    assert.deepEqual(sent.text.format.schema.required, ["view", "neckStyle", "points", "frontNeckSeamCenter"]);
    assert.equal(sent.text.format.schema.properties.backNeckSeamCenter, undefined);
    assert.ok(sent.instructions.includes("총장 상단점은 항상 앞목 중앙"));
    assert.ok(!sent.instructions.includes("backNeckSeamCenter"));
    if (refinement) assert.equal(data.refinementVersion, "outerwear-front-refinement-v3");
    assert.equal(h.calls.length, 1);
  }
});

test("v3 refuses a rear helper, missing front helper, and visible start on another face", async () => {
  const cases = [resultV2(), resultV3(), resultV3("back"), resultV3("unknown")];
  delete cases[1].frontNeckSeamCenter;
  cases[2].frontNeckSeamCenter = visible();
  cases[3].frontNeckSeamCenter = visible();
  for (const value of cases) {
    await failure(harness({ value }), request(body(), { version: 3 }), 502, "invalid_ai_response");
    await failure(harness({ value }), refinementRequest(refinementBody(), {}, 3), 502, "invalid_ai_response");
  }
});

test("v3 preserves missing front observations without requesting a rear replacement", async () => {
  for (const view of ["front", "back", "unknown"]) {
    const value = resultV3(view);
    value.frontNeckSeamCenter = hidden(view === "front" ? "occluded" : "uncertain");
    const h = harness({ value });
    const response = await h.worker.fetch(request(body(), { version: 3 }), h.env);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.deepEqual(data.frontNeckSeamCenter, value.frontNeckSeamCenter);
    assert.deepEqual(data.points, value.points);
    assert.equal(data.backNeckSeamCenter, undefined);
  }
});

function neckRequest(payload = { ...body(), regions: [{ id: "upper", image: body().image }] }) {
  return new Request("https://worker.example/v4/garments/neck-refinement", {
    method: "POST", headers: { "Content-Type": "application/json", "X-Dobby-App-Key": APP_KEY,
      Authorization: `Bearer ${INSTALLATION_ID}` }, body: JSON.stringify(payload),
  });
}
test("neck refinement asks only necks and retains direct versus estimated evidence", async () => {
  const value = { view: "front", neckStyle: "hood", points: {
    neck_left: { point: { x: 0.3, y: 0.4 }, visibility: "estimated" }, neck_right: hidden() } };
  const h = harness({ value });
  const response = await h.worker.fetch(neckRequest(), h.env);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.refinementVersion, "outerwear-side-neck-refinement-v1");
  assert.deepEqual(data.points, value.points);
  assert.equal(h.calls.length, 1);
  const sent = JSON.parse(h.calls[0].init.body);
  assert.deepEqual(sent.text.format.schema.properties.points.required, ["neck_left", "neck_right"]);
  assert.equal(sent.input[0].content.filter(c => c.type === "input_image").length, 2);
  assert.match(sent.instructions, /카라 앞쪽 끝/);
  assert.match(sent.instructions, /좌우를 독립적으로/);
  assert.match(sent.instructions, /estimated/);
});
test("neck route rejects hem crops, extra points, invalid estimates and wrong faces", async () => {
  await failure(harness(), neckRequest(lengthBody()), 400, "invalid_request");
  const valid = { view: "front", neckStyle: "collar", points: { neck_left: visible(0.3, 0.4), neck_right: hidden() } };
  for (const value of [
    { ...valid, points: { ...valid.points, shoulder_left: visible() } },
    { ...valid, points: { ...valid.points, neck_left: { point: null, visibility: "estimated" } } },
    { ...valid, points: { ...valid.points, neck_left: visible(1, 0.4) } },
    { ...valid, view: "back" },
  ]) await failure(harness({ value }), neckRequest(), 502, "invalid_ai_response");
  const h = harness({ installationAllowed: false });
  await failure(h, neckRequest(), 429, "rate_limited");
  assert.equal(h.calls.length, 0);
});

test("single-side neck requests use the new boundary definition", async () => {
  for (const target of ["neck_left", "neck_right"]) {
    const opposite = target === "neck_left" ? "neck_right" : "neck_left";
    const h = harness({ value: { view: "front", neckStyle: "collar", points: { [target]: visible(0.4, 0.35), [opposite]: hidden() } } });
    assert.equal((await h.worker.fetch(neckRequest({ ...body(), regions: [{ id: "upper", image: body().image }], target }), h.env)).status, 200);
    const sent = JSON.parse(h.calls[0].init.body);
    assert.match(sent.instructions, /어깨 윗라인이 목 옆의 카라 뿌리/);
    assert.ok(sent.instructions.includes(`대상은 화면 기준 ${target} 하나`));
    const region = sent.input[0].content.filter(c => c.type === "input_text").map(c => JSON.parse(c.text)).find(c => c.region === "upper");
    assert.deepEqual(region.targets, [target]);
  }
});
test("single-side neck rejects unknown targets and opposite-side coordinates", async () => {
  const payload = { ...body(), regions: [{ id: "upper", image: body().image }], target: "neck_left" };
  const invalid = harness();
  await failure(invalid, neckRequest({ ...payload, target: "shoulder_left" }), 400, "invalid_request");
  assert.equal(invalid.calls.length, 0);
  const h = harness({ value: { view: "front", neckStyle: "collar", points: { neck_left: visible(), neck_right: visible() } } });
  await failure(h, neckRequest(payload), 502, "invalid_ai_response");
});

test("Polo reaches current v4 landmarks and independent neck refinement unchanged", async () => {
  const whole = harness({ value: resultV4() });
  const wholeResponse = await whole.worker.fetch(request({ ...body(), category: "Polo" }, { version: 4 }), whole.env);
  assert.equal(wholeResponse.status, 200);
  assert.equal(JSON.parse(JSON.parse(whole.calls[0].init.body).input[0].content[0].text).category, "Polo");
  const detail = harness({ value: { view: "front", neckStyle: "collar", points: {
    neck_left: visible(0.4, 0.3), neck_right: hidden() } } });
  const response = await detail.worker.fetch(neckRequest({ ...body(), category: "Polo",
    regions: [{ id: "upper", image: body().image }], target: "neck_left" }), detail.env);
  assert.equal(response.status, 200);
  const sent = JSON.parse(detail.calls[0].init.body);
  assert.equal(JSON.parse(sent.input[0].content[0].text).category, "Polo");
  assert.match(sent.instructions, /대상은 화면 기준 neck_left 하나/);
});
