import test from "node:test";
import assert from "node:assert/strict";
import { buildDetailedResearchRequest, parseDetailedResearch, runDetailedResearch } from "../src/garment-detailed-research.js";
import { createWorker } from "../src/index.js";

const photos = [{ id: "front", role: "front", imageDataUrl: "data:image/jpeg;base64,fixture" }];
const brand = "ACME";
const url = "https://archive.acme.org/work-jacket";
const comparison = {
  brand, supportingQuote: "ACME 1950s denim jacket: corduroy collar, striped blanket lining, diagonal chest zip.",
  sourceUrl: url, sourceKind: "specialist_vintage", yearStart: 1950, yearEnd: 1959,
  matches: [
    { photoId: "front", visibleFeature: "코듀로이 칼라", sourceFeature: "corduroy collar" },
    { photoId: "front", visibleFeature: "줄무늬 블랭킷 안감", sourceFeature: "striped blanket lining" },
    { photoId: "front", visibleFeature: "사선 가슴 지퍼", sourceFeature: "diagonal chest zip" },
  ],
};
const heritage = { brand, sentence: "ACME는 노동 현장을 위한 커버올에 뿌리를 둔 작업복 브랜드입니다.",
  supportingQuote: "ACME supplied workwear coveralls to industrial workers.", sourceUrl: url, sourceKind: "museum" };
const payload = (value, sources = [{ url, title: "Fixture archive" }]) => ({ status: "completed", output: [
  { type: "web_search_call", status: "completed", action: { type: "search", query: "ACME work jacket", sources } },
  { type: "message", role: "assistant", content: [{ type: "output_text", text: JSON.stringify(value) }] },
] });
const response = (item = comparison) => payload({ brandFacts: [], comparisons: [item] });

test("detailed requests retain actual photos and require native research with a bounded budget", () => {
  const request = buildDetailedResearchRequest(photos, { brand }, "comparison");
  assert.equal(request.max_tool_calls, 3);
  assert.equal(request.tools[0].search_context_size, "high");
  assert.equal(request.input[0].content[2].image_url, photos[0].imageDataUrl);
  assert.match(request.instructions, /품번이 없다고 브랜드 소개 검색으로 대체하지/);
});
test("accepts museum heritage without treating it as the photographed garment's age", () => {
  const result = parseDetailedResearch(payload({ brandFacts: [heritage], comparisons: [] }), photos, brand, "brand");
  assert.equal(result.brandFacts.length, 1);
  assert.equal(result.comparisons.length, 0);
});
test("accepts explicitly tentative comparison with three source-backed structure matches", () => {
  const result = parseDetailedResearch(response(), photos, brand, "comparison");
  assert.equal(result.comparisons[0].yearEnd, 1959);
});
for (const [name, transform] of [
  ["invented URL", item => ({ ...item, sourceUrl: "https://invented.acme.org/page" })],
  ["other brand", item => ({ ...item, brand: "OTHER" })],
  ["other source type", item => ({ ...item, sourceKind: "social_post" })],
  ["unknown photo", item => ({ ...item, matches: item.matches.map(match => ({ ...match, photoId: "missing" })) })],
  ["only two matches", item => ({ ...item, matches: item.matches.slice(0, 2) })],
  ["duplicated matches", item => ({ ...item, matches: Array(3).fill(item.matches[0]) })],
  ["features absent from source", item => ({ ...item, matches: item.matches.map(match => ({ ...match, sourceFeature: "leather collar" })) })],
  ["fabricated date", item => ({ ...item, yearStart: 1930, yearEnd: 1939 })],
  ["wide date range", item => ({ ...item, yearStart: 1900, yearEnd: 2000 })],
  ["missing end year", item => ({ ...item, yearEnd: null })],
]) test(`rejects comparison with ${name}`, () => {
  assert.equal(parseDetailedResearch(response(transform(comparison)), photos, brand, "comparison").comparisons.length, 0);
});
test("requires real completed native search; unrelated tool calls cannot fabricate provenance", () => {
  const result = response(); result.output.unshift({ type: "function_call" });
  assert.throws(() => parseDetailedResearch(result, photos, brand, "comparison"));
  const noSearch = response(); noSearch.output.shift();
  assert.throws(() => parseDetailedResearch(noSearch, photos, brand, "comparison"));
});
const baseline = { searchable: true, identification: { brand },
  draft: { productName: "ACME 재킷", brand, description: "- 데님과 배색 칼라", reviewNotes: [], sources: [] } };
test("runs both investigations concurrently and links adopted evidence without claiming manufacture age", async () => {
  let started = 0, release;
  const barrier = new Promise(resolve => { release = resolve; });
  const result = await runDetailedResearch(baseline, photos, { requestResponse: async request => {
    started++; if (started === 2) release(); await barrier;
    const phase = JSON.parse(request.input[0].content[0].text).phase;
    return phase === "brand" ? payload({ brandFacts: [heritage], comparisons: [] }) : response();
  } });
  assert.equal(started, 2);
  assert.match(result.draft.description, /브랜드 배경/);
  assert.match(result.draft.description, /1950~1959년으로 분류/);
  assert.match(result.draft.description, /제조·출시 연도는 확정되지/);
  assert.equal(result.draft.sources.length, 1);
  assert.equal(result.searchCalls, 2);
});
test("retains useful photo draft and successful evidence if one research stage fails", async () => {
  const result = await runDetailedResearch(baseline, photos, { requestResponse: async request => {
    if (JSON.parse(request.input[0].content[0].text).phase === "brand") throw new Error("timeout");
    return response();
  } });
  assert.equal(result.researchStatus, "incomplete");
  assert.match(result.draft.description, /유사 제품/);
  assert.ok(result.draft.reviewNotes.some(note => note.includes("일부")));
});
test("unverified brands cannot be resurrected through detailed research", async () => {
  const result = await runDetailedResearch({ ...baseline, searchable: false }, photos, {
    requestResponse: () => { throw new Error("must not call"); },
  });
  assert.equal(result.searchCalls, 0);
});
test("test research endpoint requires the same application authorization", async () => {
  const worker = createWorker({ fetchImpl: () => { throw new Error("must not call"); } });
  const result = await worker.fetch(new Request("https://worker.example/v1/garments/autofill-research", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
  }), { OPENAI_API_KEY: "fixture", DRAFT_API_TOKEN: "fixture-token" });
  assert.equal(result.status, 401);
});
test("research route validates label bodies and returns photo-only draft when OCR is unverified", async () => {
  let calls = 0;
  const worker = createWorker({ fetchImpl: async (_url, init) => {
    calls++;
    const body = JSON.parse(init.body);
    assert.equal(body.text.format.name, "garment_identification");
    return Response.json({ status: "completed", output: [{ type: "message", role: "assistant", content: [
      { type: "output_text", text: JSON.stringify({ brand: null, productNameWithoutBrand: "데님 재킷",
        description: "- 배색 칼라의 데님 재킷", reviewNotes: [], identification: null, collaborationCandidate: null }) },
    ] }] });
  } });
  const body = { photos: [{ id: "front", role: "detail", imageDataUrl: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=" }], labelCrops: [] };
  const request = value => new Request("https://worker.example/v1/garments/autofill-research", {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer fixture-token" }, body: JSON.stringify(value),
  });
  const env = { OPENAI_API_KEY: "fixture", DRAFT_API_TOKEN: "fixture-token" };
  const result = await worker.fetch(request(body), env);
  assert.equal(result.status, 200);
  assert.equal((await result.json()).brand, null);
  assert.equal(result.headers.get("X-Dobby-AI-Search-Calls"), "0");
  assert.equal(calls, 1);
  const invalid = await worker.fetch(request({ ...body, labelCrops: [{ id: "crop", sourcePhotoId: "missing" }] }), env);
  assert.equal(invalid.status, 400);
  assert.equal(calls, 1);
});
test("long photo descriptions cannot leave adopted dates without their uncertainty notice", async () => {
  const result = await runDetailedResearch({ ...baseline, draft: { ...baseline.draft, description: "가".repeat(1180) } }, photos, {
    requestResponse: async request => JSON.parse(request.input[0].content[0].text).phase === "brand"
      ? payload({ brandFacts: [], comparisons: [] }) : response(),
  });
  assert.ok(result.draft.description.length <= 1200);
  assert.equal(result.draft.sources.length, 0);
  assert.doesNotMatch(result.draft.description, /1950/);
});
