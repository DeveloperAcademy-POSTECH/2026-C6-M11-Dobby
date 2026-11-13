import test from "node:test";
import assert from "node:assert/strict";
import { runProductAutofill } from "../src/garment-autofill.js";
import { buildBrandDiscoveryRequest, parseBrandDiscoveryResponse, buildBrandReadbackRequest } from "../src/garment-brand-discovery.js";
import { unmatchedDiscoveryResponse } from "./helpers/native-discovery.js";

// Injected fixtures only. Quotes, URLs, labels and products are not live evidence.
const PHOTOS = [{ id: "label-1", role: "detail", imageDataUrl: "data:image/png;base64,fixture" }];
const DRAFT = { brand: null, productNameWithoutBrand: "화이트 그래픽 반팔 티셔츠",
  description: "- 화이트 바탕의 그래픽 프린트", reviewNotes: [] };
const SOURCE = "https://www.palaceskateboards.com/fixture-about";
const BRAND = { originalName: "PALACE", localizedName: "팔라스", photoId: "label-1", observedText: "PALACE",
  confidence: "high", sourceUrl: SOURCE, sourceKind: "official_about", supportingQuote: "PALACE is a skateboarding brand." };
const FACT = { type: "brand_heritage", yearStart: null, yearEnd: null,
  sentence: "PALACE는 스케이트 영상 문화를 고유한 그래픽 전통으로 발전시켜 온 브랜드입니다.",
  sourceUrl: SOURCE, subjectBrand: "PALACE", subjectIdentifier: "PALACE",
  supportingQuote: "PALACE has a lasting graphic tradition rooted in skate video culture.",
  sourceKind: "official_about", heritageBasis: "cultural_legacy" };
function message(value) { return { type: "message", role: "assistant", phase: "final_answer",
  content: [{ type: "output_text", text: JSON.stringify(value) }] }; }
function baseline(draft = DRAFT) { return { status: "completed", output: [message({ ...draft, identification: null })] }; }
function discovery(brand = BRAND, facts = [], sources = [{ title: "Fixture official brand page", url: SOURCE }]) {
  return { status: "completed", output: [
    { type: "web_search_call", status: "completed", action: { type: "search", query: "fixture triangle label", sources } },
    message({ brand, facts, nextQuery: "" }),
  ] };
}
function readback(overrides = {}) {
  return { status: "completed", output: [message({ brand: {
    originalName: "PALACE", localizedName: "팔라스", photoId: "label-1", observedText: "PALACE",
    confidence: "high", location: "neck_print", ...overrides,
  } })] };
}
function heritage() {
  return { status: "completed", output: [
    { type: "web_search_call", status: "completed", action: { type: "search", query: "PALACE official heritage", sources: [] } },
    message({ facts: [], nextQuery: "", collaboration: null }),
  ] };
}
function harness(responses, verifyKnownBrand = false, labelCrops) {
  const requests = [];
  return { requests, run: () => runProductAutofill(PHOTOS, { verifyKnownBrand, labelCrops, requestResponse: async request => {
    requests.push(request);
    const response = responses[requests.length - 1];
    assert.notEqual(response, undefined, "search exceeded its bounded request budget");
    if (response instanceof Error) throw response;
    return response;
  } }) };
}

test("unknown brand search sees original images and requires one native web search", () => {
  const request = buildBrandDiscoveryRequest(PHOTOS, { productName: DRAFT.productNameWithoutBrand, description: DRAFT.description });
  assert.equal(request.tool_choice, "required");
  assert.equal(request.max_tool_calls, 1);
  assert.equal(request.store, false);
  assert.deepEqual(request.tools.map(tool => tool.type), ["web_search"]);
  assert.match(request.instructions, /브랜드가 판독되지 않아도 반드시 web_search/);
  assert.deepEqual(request.input[0].content.filter(part => part.type === "input_image").map(part => part.image_url), PHOTOS.map(p => p.imageDataUrl));
  assert.equal(JSON.stringify(request).includes("PALACE"), false, "a failed brand must not become a hard-coded search hint");
});

test("a valid garment with no identified brand still completes search", async () => {
  const h = harness([baseline(), unmatchedDiscoveryResponse()]);
  const result = await h.run();
  assert.equal(h.requests.length, 2);
  assert.equal(result.searchAttempts, 1);
  assert.equal(result.searchCalls, 1);
  assert.equal(result.researchStatus, "no_match");
  assert.equal(result.draft.brand, null);
  assert.equal(result.draft.productName, DRAFT.productNameWithoutBrand);
});

test("photo and search evidence recover the brand and retain its source without inventing product facts", async () => {
  const h = harness([baseline(), discovery(), readback(), heritage()]);
  const result = await h.run();
  assert.equal(h.requests.length, 4);
  assert.equal(result.searchAttempts, 2);
  assert.equal(result.searchCalls, 2);
  assert.equal(result.researchStatus, "matched");
  assert.equal(result.draft.brand, "PALACE (팔라스)");
  assert.equal(result.draft.productName, `팔라스 ${DRAFT.productNameWithoutBrand}`);
  assert.equal(result.draft.description, DRAFT.description);
  assert.deepEqual(result.draft.sources.map(s => s.url), [SOURCE]);
  assert.equal(h.requests[3].input[0].content.some(part => part.type === "input_image"), false);
});

test("discovery can include verified heritage in the same search without another search", async () => {
  const h = harness([baseline(), discovery(BRAND, [FACT]), readback()]);
  const result = await h.run();
  assert.equal(result.searchCalls, 1);
  assert.equal(result.draft.brand, "PALACE (팔라스)");
  assert.ok(result.draft.description.endsWith(FACT.sentence));
  assert.deepEqual(result.draft.sources.map(s => s.url), [SOURCE]);
});

test("a source cannot replace photographic evidence and weak search guesses never fill the brand", async t => {
  for (const [name, brand, sources] of [
    ["unknown source", { ...BRAND, sourceUrl: "https://www.palaceskateboards.com/not-returned" }],
    ["wrong photo", { ...BRAND, photoId: "not-selected" }],
    ["low confidence", { ...BRAND, confidence: "low" }],
    ["medium confidence", { ...BRAND, confidence: "medium" }],
    ["unread letters", { ...BRAND, observedText: "PAL" }],
    ["unrelated quote", { ...BRAND, supportingQuote: "A generic graphic garment." }],
    ["resale evidence", { ...BRAND, sourceKind: "resale_listing" }],
    ["no native sources", BRAND, []],
  ]) {
    await t.test(name, async () => {
      const h = harness([baseline(), discovery(brand, [FACT], sources)]);
      const result = await h.run();
      assert.equal(result.searchCalls, 1);
      assert.equal(result.draft.brand, null);
      assert.equal(result.draft.description, DRAFT.description);
      assert.equal(result.draft.sources, undefined);
    });
  }
});

test("a failed discovery search records an attempt without falsely claiming a completed search", async () => {
  const h = harness([baseline(), new Error("search failed")]);
  const result = await h.run();
  assert.equal(result.searchAttempts, 1);
  assert.equal(result.searchCalls, 0);
  assert.equal(result.researchStatus, "incomplete");
  assert.equal(result.draft.brand, null);
});

test("recovered identity survives a later research outage with its verified source", async () => {
  const h = harness([baseline(), discovery(), readback(), new Error("research timeout")]);
  const result = await h.run();
  assert.equal(result.draft.brand, "PALACE (팔라스)");
  assert.equal(result.searchAttempts, 2);
  assert.equal(result.searchCalls, 1);
  assert.equal(result.researchStatus, "incomplete");
  assert.deepEqual(result.draft.sources.map(s => s.url), [SOURCE]);
});

test("model prose without a completed native tool call is not a search", () => {
  const response = discovery();
  response.output.shift();
  assert.throws(() => parseBrandDiscoveryResponse(response, PHOTOS));
  const extra = discovery(); extra.output.unshift({ type: "function_call", name: "fake_search" });
  assert.throws(() => parseBrandDiscoveryResponse(extra, PHOTOS));
});


test("independent readback sees labels without any search candidate or search source", () => {
  const request = buildBrandReadbackRequest(PHOTOS);
  assert.equal(request.tools, undefined);
  assert.equal(JSON.stringify(request).includes("PALACE"), false);
  assert.equal(JSON.stringify(request).includes("Thrasher"), false);
  assert.deepEqual(request.input[0].content.filter(p => p.type === "input_image").map(p => p.image_url), PHOTOS.map(p => p.imageDataUrl));
});

test("a similar graphic search result cannot replace the independently photographed label", async () => {
  const wrongURL = "https://www.fixture-retailer.com/fixture-thrasher";
  const wrong = { ...BRAND, originalName: "Thrasher", localizedName: null, observedText: "Thrasher",
    sourceUrl: wrongURL, sourceKind: "retailer_product", supportingQuote: "Thrasher graphic T-shirt." };
  const h = harness([baseline(), discovery(wrong, [], [{ title: "Other garment", url: wrongURL }]), readback(), heritage()]);
  const result = await h.run();
  assert.equal(result.draft.brand, "PALACE (팔라스)");
  assert.equal(result.searchCalls, 2);
  assert.deepEqual(result.draft.sources, []);
  assert.equal(JSON.stringify(result.draft).includes("Thrasher"), false);
  assert.equal(JSON.stringify(h.requests[3]).includes("Thrasher"), false);
});

test("body graphics and failed independent label readback cannot confirm a search candidate", async t => {
  for (const [name, response] of [
    ["body graphic", readback({ location: "body_graphic" })],
    ["uncertain text", readback({ confidence: "medium" })],
    ["transport failure", new Error("readback failed")],
  ]) {
    await t.test(name, async () => {
      const h = harness([baseline(), discovery(), response]);
      const result = await h.run();
      assert.equal(result.draft.brand, null);
      assert.equal(result.draft.sources, undefined);
      assert.equal(result.searchCalls, 1);
      assert.equal(result.searchAttempts, 1);
    });
  }
});

function confidentlyWrongBaseline() {
  return { status: "completed", output: [message({ ...DRAFT,
    brand: { originalName: "HELLSTAR", localizedName: "헬스타" },
    identification: { brand: "HELLSTAR", productCode: "WRONG-123", modelName: null, manufactureYear: null,
      evidence: [
        { kind: "brand_label", text: "HELLSTAR", photoId: "label-1", confidence: "high" },
        { kind: "product_code", text: "WRONG-123", photoId: "label-1", confidence: "high" },
      ] },
  })] };
}

test("confident wrong initial brand is replaced by independent neck label before any search", async () => {
  const h = harness([confidentlyWrongBaseline(), readback(), heritage()], true);
  const result = await h.run();
  assert.equal(h.requests[1].text.format.name, "garment_brand_readback");
  assert.equal(JSON.stringify(h.requests[1]).includes("HELLSTAR"), false);
  assert.equal(h.requests[2].tools[0].type, "web_search");
  assert.match(JSON.stringify(h.requests[2]), /PALACE/);
  assert.doesNotMatch(JSON.stringify(h.requests[2]), /HELLSTAR|WRONG-123/);
  assert.equal(result.draft.brand, "PALACE (팔라스)");
  assert.doesNotMatch(JSON.stringify(result.draft), /HELLSTAR|헬스타/);
  assert.equal(result.searchAttempts, 1);
  assert.equal(result.searchCalls, 1);
});

test("independent known-brand readback failure preserves generation and still attempts search", async () => {
  const h = harness([confidentlyWrongBaseline(), new Error("vision timeout"), heritage()], true);
  const result = await h.run();
  assert.equal(result.searchCalls, 1);
  assert.ok(result.draft.reviewNotes.some(note => note.includes("독립 라벨 판독을 완료하지 못")));
});

test("body graphic readback cannot override an initially identified label", async () => {
  const h = harness([confidentlyWrongBaseline(), readback({ location: "body_graphic" }), heritage()], true);
  const result = await h.run();
  assert.equal(result.draft.brand, "HELLSTAR (헬스타)");
  assert.ok(result.draft.reviewNotes.some(note => note.includes("재확인하지 못")));
});

test("agreeing independent label keeps the original photographed product identifier", async () => {
  const h = harness([confidentlyWrongBaseline(), readback({ originalName: "HELLSTAR", localizedName: "헬스타", observedText: "HELLSTAR" }), heritage()], true);
  const result = await h.run();
  assert.match(JSON.stringify(h.requests[2]), /WRONG-123/);
  assert.equal(result.draft.brand, "HELLSTAR (헬스타)");
  assert.equal(result.searchCalls, 1);
});


const APP_CROPS = [{ id: "crop-1", sourcePhotoId: "label-1", role: "label", imageDataUrl: PHOTOS[0].imageDataUrl,
  ocrText: "45°: PALACE\n90°: PALACE" }];
function croppedReading() { return { status: "completed", output: [message({
  readings: [{ photoId: "crop-1", text: "PALACE", legibility: "clear" }],
  brand: { originalName: "PALACE", localizedName: "팔라스", photoId: "crop-1", observedText: "PALACE", confidence: "high" },
})] }; }
test("app label OCR replaces wrong initial brand and searches only verified identity", async () => {
  const h = harness([confidentlyWrongBaseline(), croppedReading(), heritage()], false, APP_CROPS);
  const result = await h.run();
  assert.equal(result.draft.brand, "PALACE (팔라스)");
  assert.equal(h.requests[1].text.format.name, "garment_cropped_label_readings");
  assert.doesNotMatch(JSON.stringify(h.requests[2]), /HELLSTAR|WRONG-123/);
  assert.match(JSON.stringify(h.requests[2]), /PALACE/);
  assert.equal(result.searchCalls, 1);
});
test("app missing OCR keeps brand empty even if initial analysis and search confidently guess one", async () => {
  const h = harness([confidentlyWrongBaseline(), discovery()], false, []);
  const result = await h.run();
  assert.equal(result.draft.brand, null);
  assert.doesNotMatch(result.draft.productName, /HELLSTAR|헬스타/);
  assert.equal(result.searchCalls, 1);
});
test("app OCR read failure preserves unbranded features and still searches", async () => {
  const h = harness([confidentlyWrongBaseline(), new Error("label read failed"), discovery()], false, APP_CROPS);
  const result = await h.run();
  assert.equal(result.draft.brand, null);
  assert.equal(result.draft.description, DRAFT.description);
  assert.equal(result.searchCalls, 1);
});

test("app label reading starts before photo analysis finishes", async () => {
  let finishInitial;
  let labelStarted = false;
  const initial = new Promise(resolve => { finishInitial = resolve; });
  const work = runProductAutofill(PHOTOS, { labelCrops: APP_CROPS, requestResponse: async request => {
    if (request.text.format.name === "garment_identification") return initial;
    if (request.text.format.name === "garment_cropped_label_readings") { labelStarted = true; return croppedReading(); }
    return heritage();
  } });
  const startedBeforeBaselineFinished = labelStarted;
  finishInitial(confidentlyWrongBaseline());
  const result = await work;
  assert.equal(startedBeforeBaselineFinished, true);
  assert.equal(result.draft.brand, "PALACE (팔라스)");
});
