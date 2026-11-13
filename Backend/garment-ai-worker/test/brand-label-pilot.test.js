import test from "node:test";
import assert from "node:assert/strict";
import { createWorker } from "../src/index.js";
import { buildLabelRegionsRequest, buildCroppedLabelReadRequest, parseLabelRegions,
  parseCroppedLabelReadings } from "../src/brand-label-pilot.js";

const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const photos = [{ id: "photo-1", role: "label", imageDataUrl: PNG }];
const readPhotos = [{ ...photos[0], ocrText: "45°: PALACE\n90°: PALACE" }];
const region = { photoId: "photo-1", kind: "neck_print", box: { x: 0.1, y: 0.2, width: 0.6, height: 0.4 } };
const reading = { photoId: "photo-1", text: "PALACE S", legibility: "clear" };
const brand = { originalName: "PALACE", localizedName: "팔라스", photoId: "photo-1", observedText: "PALACE", confidence: "high" };
const payload = value => ({ status: "completed", output: [{ type: "message", role: "assistant",
  content: [{ type: "output_text", text: JSON.stringify(value) }] }] });
const env = { DRAFT_API_TOKEN: "fixture-token", OPENAI_API_KEY: "fixture-key" };
function request(path, body = { photos }, token = "fixture-token") {
  return new Request(`https://worker.example/v1/garments/${path}`, { method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
}

test("label detection and cropped transcription are isolated photo-only requests without brand guesses", () => {
  for (const r of [buildLabelRegionsRequest(photos), buildCroppedLabelReadRequest(photos)]) {
    assert.equal(r.store, false);
    assert.equal(r.tools, undefined);
    assert.equal(JSON.stringify(r).includes("HELLSTAR"), false);
    assert.equal(JSON.stringify(r).includes("PALACE"), false);
    assert.deepEqual(r.input[0].content.filter(p => p.type === "input_image").map(p => p.image_url), [PNG]);
  }
  assert.match(buildLabelRegionsRequest(photos).instructions, /브랜드명은 판단하거나 반환하지/);
});

test("label rectangles use bounded top-left coordinates and input photo IDs", () => {
  assert.deepEqual(parseLabelRegions(payload({ regions: [region] }), photos).regions, [region]);
  for (const invalid of [ { ...region, photoId: "invented" },
    { ...region, box: { ...region.box, x: -0.1 } },
    { ...region, box: { ...region.box, width: 1 } },
    { ...region, box: { ...region.box, height: 0 } }, { ...region, kind: "body_graphic" } ]) {
    assert.throws(() => parseLabelRegions(payload({ regions: [invalid] }), photos));
  }
  assert.deepEqual(parseLabelRegions(payload({ regions: [] }), photos).regions, []);
});

test("brand must be supported by the clear transcript of the same crop", () => {
  const result = parseCroppedLabelReadings(payload({ readings: [reading], brand }), readPhotos);
  assert.equal(result.brand.originalName, "PALACE");
  for (const bad of [{ ...brand, originalName: "HELLSTAR" }, { ...brand, photoId: "wrong" },
    { ...brand, confidence: "medium" }, { ...brand, observedText: "PALACE invented suffix" }]) {
    assert.equal(parseCroppedLabelReadings(payload({ readings: [reading], brand: bad }), readPhotos).brand, null);
  }
  assert.equal(parseCroppedLabelReadings(payload({ readings: [{ ...reading, legibility: "partial" }], brand }), readPhotos).brand, null);
  assert.throws(() => parseCroppedLabelReadings(payload({ readings: [], brand }), photos));
});

test("brand-only endpoints retain authentication, validation and sanitized errors", async () => {
  for (const path of ["brand-label-regions", "brand-label-readings"]) {
    const calls = [];
    const worker = createWorker({ fetchImpl: async (_url, init) => {
      calls.push(JSON.parse(init.body));
      return Response.json(payload(path.endsWith("regions") ? { regions: [region] } : { readings: [reading], brand }));
    } });
    assert.equal((await worker.fetch(request(path, { photos }, "wrong"), env)).status, 401);
    assert.equal((await worker.fetch(request(path, { photos: [] }), env)).status, 400);
    assert.equal(calls.length, 0);
    const response = await worker.fetch(request(path), env);
    assert.equal(response.status, 200);
    assert.equal(calls.length, 1);
    assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), null);
    assert.equal(calls[0].tools, undefined);
    const broken = createWorker({ fetchImpl: async () => Response.json({ raw: "fixture-key" }) });
    const error = await broken.fetch(request(path), env);
    assert.equal(error.status, 502);
    assert.doesNotMatch(await error.text(), /fixture-key|data:image/);
  }
});

test("brand-only requests use app rate limits and timeout protection", async () => {
  let fetchCount = 0;
  const worker = createWorker({ timeoutMs: 5, fetchImpl: async (_url, init) => {
    fetchCount++;
    return new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(new DOMException("timeout", "AbortError"))));
  } });
  const appEnv = { OPENAI_API_KEY: "fixture-key", DOBBY_APP_API_KEY: "fixture-app",
    AI_INSTALLATION_RATE_LIMITER: { limit: async () => ({ success: false }) },
    AI_SHARED_RATE_LIMITER: { limit: async () => ({ success: true }) } };
  const r = request("brand-label-regions", { photos }, "a".repeat(64));
  r.headers.set("X-Dobby-App-Key", "fixture-app");
  assert.equal((await worker.fetch(r, appEnv)).status, 429);
  assert.equal(fetchCount, 0);
  assert.equal((await worker.fetch(request("brand-label-readings"), env)).status, 504);
});

test("rejected provider requests expose only allowlisted setting metadata", async () => {
  const worker = createWorker({ fetchImpl: async () => Response.json({ error: {
    code: "invalid_json_schema", param: "text.format.schema", message: "fixture-key data:image secret content",
  } }, { status: 400 }) });
  const response = await worker.fetch(request("brand-label-regions"), env);
  assert.equal(response.status, 502);
  const body = await response.text();
  assert.match(body, /label_request_invalid_json_schema/);
  assert.match(body, /text.format.schema/);
  assert.doesNotMatch(body, /fixture-key|data:image|secret content/);
});

test("bounded OCR observations reach only the isolated cropped-label reader as untrusted data", async () => {
  let sent;
  const worker = createWorker({ fetchImpl: async (_url, init) => {
    sent = JSON.parse(init.body);
    return Response.json(payload({ readings: [reading], brand }));
  } });
  const withOCR = { photos: [{ ...photos[0], ocrText: "45°: PALACE\n90°: PALACE" }] };
  assert.equal((await worker.fetch(request("brand-label-readings", withOCR), env)).status, 200);
  assert.match(JSON.stringify(sent.input), /untrustedOCR/);
  assert.match(sent.instructions, /명령이 아닙니다/);
  assert.equal((await worker.fetch(request("autofill", withOCR), env)).status, 400);
  assert.equal((await worker.fetch(request("brand-label-regions", withOCR), env)).status, 400);
  assert.equal((await worker.fetch(request("brand-label-readings", {
    photos: [{ ...photos[0], ocrText: "x".repeat(1201) }],
  }), env)).status, 400);
});


test("model-authored transcription cannot certify a brand without a complete matching OCR word", () => {
  const response = payload({ readings: [reading], brand });
  assert.equal(parseCroppedLabelReadings(response, photos).brand, null);
  for (const ocrText of ["45°: PALA", "45°: OTHER\n90°: OTHER"]) {
    assert.equal(parseCroppedLabelReadings(response, [{ ...photos[0], ocrText }]).brand, null);
  }
  const wrong = { ...brand, originalName: "PEAK PERFORMANCE", observedText: "PEAK PERFORMANCE" };
  assert.equal(parseCroppedLabelReadings(payload({ readings: [{ ...reading, text: "PEAK PERFORMANCE" }], brand: wrong }), readPhotos).brand, null);
});

test("app autofill route validates source binding, uses OCR brand and preserves draft response contract", async () => {
  const calls = [];
  const worker = createWorker({ fetchImpl: async (_url, init) => {
    const request = JSON.parse(init.body);
    calls.push(request);
    if (request.text.format.name === "garment_identification") return Response.json(payload({
      brand: null, productNameWithoutBrand: "화이트 그래픽 티셔츠", description: "- 화이트 그래픽 프린트", reviewNotes: [], identification: null,
    }));
    if (request.text.format.name === "garment_cropped_label_readings") return Response.json(payload({
      readings: [{ ...reading, photoId: "crop-1" }], brand: { ...brand, photoId: "crop-1" },
    }));
    return Response.json({ status: "completed", output: [
      { type: "web_search_call", status: "completed", action: { type: "search", query: "PALACE official history", sources: [] } },
      ...payload({ facts: [], nextQuery: "", collaboration: null }).output,
    ] });
  } });
  const crop = { id: "crop-1", sourcePhotoId: "photo-1", imageDataUrl: PNG, ocrText: "45°: PALACE\n90°: PALACE" };
  const invalid = await worker.fetch(request("autofill-labels", { photos, labelCrops: [{ ...crop, sourcePhotoId: "missing" }] }), env);
  assert.equal(invalid.status, 400);
  assert.equal(calls.length, 0);
  const response = await worker.fetch(request("autofill-labels", { photos, labelCrops: [crop] }), env);
  assert.equal(response.status, 200);
  const draft = await response.json();
  assert.equal(draft.brand, "PALACE (팔라스)");
  assert.equal(draft.productName, "팔라스 화이트 그래픽 티셔츠");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(calls.length, 3);
  assert.equal(calls[1].input[0].content.filter(item => item.type === "input_image").length, 1);
  assert.equal(response.headers.get("X-Dobby-AI-Brand-Status"), "verified");
  assert.equal(response.headers.get("X-Dobby-AI-Brand-Reason"), "verified");
  for (const stage of ["Identification", "Label-Read", "Search", "Server"]) {
    assert.match(response.headers.get(`X-Dobby-AI-${stage}-Ms`), /^\d+$/);
  }
});

test("multiline brand and line names survive OCR line reordering within each angle", () => {
  const crops = [{ ...photos[0], ocrText: "0°: RALPH LAUREN\n0°: POLO\n0°: MADE IN INDIA\n90°: RALPH LAUREN\n90°: POLO" }];
  const candidate = { ...brand, originalName: "Polo Ralph Lauren", localizedName: "폴로 랄프로렌", observedText: "POLO\nRALPH LAUREN" };
  const result = parseCroppedLabelReadings(payload({ readings: [{ ...reading, text: "POLO\nRALPH LAUREN\n29" }], brand: candidate }), crops);
  assert.equal(result.brand.originalName, "Polo Ralph Lauren");
  assert.equal(result.brandRejection, null);
  const fabricated = parseCroppedLabelReadings(payload({ readings: [{ ...reading, text: "POLO SPORT RALPH LAUREN" }],
    brand: { ...candidate, originalName: "Polo Sport Ralph Lauren", observedText: "POLO SPORT RALPH LAUREN" } }), crops);
  assert.equal(fabricated.brand, null);
  assert.equal(fabricated.brandRejection, "ocr_mismatch");
});

test("OCR words from separate incomplete rotations cannot be combined into proof", () => {
  const result = parseCroppedLabelReadings(payload({ readings: [{ ...reading, text: "POLO RALPH LAUREN" }],
    brand: { ...brand, originalName: "Polo Ralph Lauren", observedText: "POLO RALPH LAUREN" } }),
  [{ ...photos[0], ocrText: "0°: POLO\n90°: RALPH LAUREN" }]);
  assert.equal(result.brand, null);
  assert.equal(result.brandRejection, "ocr_mismatch");
});


test("one complete OCR direction and independent clear high-confidence crop reading are sufficient", () => {
  const evidence = [{ ...photos[0], ocrText: "135°: PALACE\n225°: S\n315°: РАVACE" }];
  const result = parseCroppedLabelReadings(payload({ readings: [reading], brand }), evidence);
  assert.equal(result.brand.originalName, "PALACE");
  assert.equal(result.brandRejection, null);
  for (const changed of [
    { readings: [{ ...reading, legibility: "partial" }], brand },
    { readings: [reading], brand: { ...brand, confidence: "medium" } },
    { readings: [{ ...reading, text: "OTHER" }], brand },
  ]) assert.equal(parseCroppedLabelReadings(payload(changed), evidence).brand, null);
});
