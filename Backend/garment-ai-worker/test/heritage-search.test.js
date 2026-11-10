import { unmatchedDiscoveryResponse } from "./helpers/native-discovery.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createWorker } from "../src/index.js";
import {
  buildIdentificationRequest, parseIdentificationResponse,
  buildHeritageSearchRequest, parseHeritageSearchResponse,
  appendHeritageToDraft,
} from "../src/garment-heritage.js";

// All products, dates, quotes, URLs, and images in this file are injected fixtures.
// No test calls OpenAI or searches the network.
const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const PHOTOS = [{ id: "label-1", role: "label", imageDataUrl: PNG }];
const DRAFT = {
  brand: { originalName: "NIKE", localizedName: "나이키" },
  productNameWithoutBrand: "블랙 배색 집업 재킷",
  description: "블랙 바탕의 집업 재킷입니다.\n\n배색이 실루엣에 포인트를 더합니다.",
  reviewNotes: [],
};
const PUBLIC_DRAFT = {
  productName: "나이키 블랙 배색 집업 재킷", brand: "NIKE (나이키)",
  description: DRAFT.description, reviewNotes: ["하자·오염 상태 실물 확인 필요"],
};
const IDENTIFICATION = {
  brand: "NIKE", productCode: "123456-010", modelName: null, manufactureYear: null,
  evidence: [
    { kind: "brand_label", text: "NIKE", photoId: "label-1", confidence: "high" },
    { kind: "product_code", text: "123456-010", photoId: "label-1", confidence: "high" },
  ],
};
const SOURCE = "https://www.nike.com/t/fixture-123456-010";
const FACT = {
  type: "year_release", yearStart: 1998, yearEnd: null,
  sentence: "1998년에 처음 선보인 모델입니다.", sourceUrl: SOURCE,
  heritageBasis: null,
  sourceKind: "official_archive",
  subjectBrand: "NIKE", subjectIdentifier: "123456-010",
  supportingQuote: "NIKE 123456-010 was first released in 1998.",
};
const BRAND_SOURCE = "https://about.nike.com/en/fixture-history";
const BRAND_SOURCES = [{ title: "Fixture official brand history", url: BRAND_SOURCE }];
const BRAND_FACT = {
  type: "brand_heritage", yearStart: null, yearEnd: null,
  sentence: "NIKE는 러닝에서 출발해 와플 아웃솔을 상징적인 디자인 전통으로 발전시켜 온 브랜드입니다.",
  heritageBasis: "signature_tradition",
  sourceUrl: BRAND_SOURCE, sourceKind: "official_history",
  subjectBrand: "NIKE", subjectIdentifier: "NIKE",
  supportingQuote: "NIKE's running heritage established the waffle outsole as a lasting signature design tradition.",
};
const BRAND_PARAGRAPH = BRAND_FACT.sentence;
// Synthetic Stone Island-like fixtures exercise brand R&D wording, not a user's garment or a live page.
const RESEARCH_BRAND = {
  brand: "STONE ISLAND", productCode: null, modelName: null, manufactureYear: null,
  evidence: [{ kind: "brand_label", text: "STONE ISLAND", photoId: "label-1", confidence: "high" }],
};
const RESEARCH_SOURCE = "https://www.stoneisland.com/fixture-material-research";
const RESEARCH_FACT = {
  ...BRAND_FACT, subjectBrand: "STONE ISLAND", subjectIdentifier: "STONE ISLAND",
  sourceUrl: RESEARCH_SOURCE,
  sentence: "STONE ISLAND는 소재 연구와 가먼트 다잉 실험을 상징적인 디자인 전통으로 발전시켜 온 브랜드입니다.",
  supportingQuote: "STONE ISLAND has an established heritage of material research, garment experimentation and garment dyeing as a lasting signature tradition.",
};

function assistant(value, { annotations = [], phase = "final_answer" } = {}) {
  return { type: "message", role: "assistant", phase,
    content: [{ type: "output_text", text: JSON.stringify(value), annotations }] };
}

function baseline(identification = IDENTIFICATION, draft = DRAFT) {
  return { status: "completed", output: [assistant({ ...draft, identification })] };
}

function searchResponse(facts = [FACT], { calls, sources = [{ title: "Fixture product archive", url: SOURCE }],
  annotations = [], nextQuery = "NIKE 123456-010 archive release" } = {}) {
  return {
    status: "completed",
    output: [
      ...(calls ?? [{ type: "web_search_call", status: "completed", action: {
        type: "search", query: "NIKE 123456-010", sources,
      } }]),
      assistant({ facts, nextQuery }, { annotations }),
    ],
  };
}

function identification(overrides = {}) {
  return { ...IDENTIFICATION, ...overrides };
}

function photoRequest() {
  return new Request("https://worker.example/v1/garments/autofill", {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer test-token" },
    body: JSON.stringify({ photos: PHOTOS }),
  });
}

function workerHarness(responses, options = {}) {
  const calls = [];
  const worker = createWorker({ ...options, fetchImpl: async (url, init) => {
    const outgoing = { url: String(url), init, body: JSON.parse(init.body) };
    if (outgoing.body.text?.format?.name === "garment_brand_readback") {
      return Response.json({ status: "completed", output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: JSON.stringify({ brand: null }) }] }] });
    }
    calls.push(outgoing);
    const next = responses[calls.length - 1];
    assert.notEqual(next, undefined, "unexpected extra upstream request");
    if (typeof next === "function") return next(init);
    return Response.json(next);
  } });
  return { worker, calls, env: { DRAFT_API_TOKEN: "test-token", OPENAI_API_KEY: "test-key" } };
}

function assertPhotoOnly(result, notePattern) {
  assert.equal(result.productName, PUBLIC_DRAFT.productName);
  assert.equal(result.brand, PUBLIC_DRAFT.brand);
  assert.equal(result.description, PUBLIC_DRAFT.description);
  assert.equal(result.sources, undefined);
  assert.ok(PUBLIC_DRAFT.reviewNotes.every(note => result.reviewNotes.includes(note)));
  assert.ok(result.reviewNotes.some(note => notePattern.test(note)));
}

test("photo identification remains a fixed Luna vision request without web tools", () => {
  const sent = buildIdentificationRequest(PHOTOS);
  assert.equal(sent.model, "gpt-6-luna");
  assert.equal(sent.store, false);
  assert.ok(!sent.tools || sent.tools.length === 0);
  assert.equal(sent.text.format.strict, true);
  assert.ok(sent.text.format.schema.required.includes("identification"));
  const images = sent.input.flatMap(item => item.content ?? []).filter(item => item.type === "input_image");
  assert.deepEqual(images.map(item => item.image_url), [PNG]);
});

test("confirmed label and product code enable research without changing existing brand formatting", () => {
  const parsed = parseIdentificationResponse(baseline(), PHOTOS);
  assert.equal(parsed.searchable, true);
  assert.equal(parsed.identification.productCode, "123456-010");
  assert.deepEqual(parsed.draft, PUBLIC_DRAFT);
});

test("unconfirmed brands still perform search while preserving unverified photo fields", async t => {
  const cases = [
    ["no identity", null],
    ["no photographed brand", identification({ evidence: IDENTIFICATION.evidence.slice(1) })],
    ["unavailable photo", identification({ evidence: IDENTIFICATION.evidence.map(item => ({ ...item, photoId: "not-selected" })) })],
    ["low confidence brand", identification({ evidence: IDENTIFICATION.evidence.map(item => ({ ...item, confidence: "low" })) })],
    ["conflicting brand", identification({ brand: "ADIDAS" })],
  ];
  for (const [name, value] of cases) {
    await t.test(name, async () => {
      const parsed = parseIdentificationResponse(baseline(value), PHOTOS);
      assert.equal(parsed.searchable, false);
      assert.deepEqual(parsed.draft, PUBLIC_DRAFT);
      const h = workerHarness([baseline(value), unmatchedDiscoveryResponse()]);
      const response = await h.worker.fetch(photoRequest(), h.env);
      assert.equal(response.status, 200);
      assertPhotoOnly(await response.json(), /검색했지만 브랜드/);
      assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
      assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "1");
      assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
      assert.equal(h.calls.length, 2);
    });
  }
});

test("a photographed brand can research its heritage while unproven product identifiers are dropped", async t => {
  const cases = [
    ["brand alone", identification({ productCode: null, evidence: IDENTIFICATION.evidence.slice(0, 1) })],
    ["no photographed code", identification({ evidence: IDENTIFICATION.evidence.slice(0, 1) })],
    ["low confidence code", identification({ evidence: [IDENTIFICATION.evidence[0],
      { ...IDENTIFICATION.evidence[1], confidence: "low" }] })],
    ["conflicting code", identification({ productCode: "654321-100" })],
    ["code is only a prefix of label variant", identification({ evidence: [IDENTIFICATION.evidence[0],
      { ...IDENTIFICATION.evidence[1], text: "123456-010-RED" }] })],
  ];
  for (const [name, value] of cases) {
    await t.test(name, async () => {
      const parsed = parseIdentificationResponse(baseline(value), PHOTOS);
      assert.equal(parsed.searchable, true);
      assert.equal(parsed.identification.brand, "NIKE");
      assert.equal(parsed.identification.productCode, null);
      assert.equal(parsed.identification.modelName, null);
      const h = workerHarness([baseline(value), searchResponse([BRAND_FACT], { sources: BRAND_SOURCES })]);
      const response = await h.worker.fetch(photoRequest(), h.env);
      assert.equal(response.status, 200);
      const result = await response.json();
      assert.ok(result.description.endsWith(`\n\n${BRAND_PARAGRAPH}`));
      assert.deepEqual(result.sources.map(source => source.url), [BRAND_SOURCE]);
      assert.equal(h.calls.length, 2);
      assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
    });
  }
});

test("confirmed model text can identify a product without a product code", () => {
  const value = identification({ productCode: null, modelName: "Fixture Air Jacket", evidence: [
    IDENTIFICATION.evidence[0],
    { kind: "model_name", text: "Fixture Air Jacket", photoId: "label-1", confidence: "high" },
  ] });
  assert.equal(parseIdentificationResponse(baseline(value), PHOTOS).searchable, true);
});

test("an unknown photographed brand always searches without accepting an unproven guessed identity", async () => {
  const h = workerHarness([baseline(IDENTIFICATION, { ...DRAFT, brand: null }), unmatchedDiscoveryResponse()]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.brand, null);
  assert.equal(result.productName, DRAFT.productNameWithoutBrand);
  assert.equal(result.sources, undefined);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
  assert.equal(h.calls.length, 2);
});

test("a search attempt requires one native search and requests source provenance", () => {
  const sent = buildHeritageSearchRequest({ identification: IDENTIFICATION });
  assert.equal(sent.model, "gpt-6-luna");
  assert.equal(sent.store, false);
  assert.equal(sent.tool_choice, "required");
  assert.equal(sent.max_tool_calls, 1);
  assert.deepEqual(sent.tools.map(tool => tool.type), ["web_search"]);
  assert.ok(sent.include.includes("web_search_call.action.sources"));
  assert.equal(sent.text.format.strict, true);
  assert.ok(JSON.stringify(sent.input).includes("123456-010"));
});

test("brand research receives garment relevance as text without adding another image-analysis request", () => {
  const brandOnly = identification({ productCode: null, evidence: IDENTIFICATION.evidence.slice(0, 1) });
  const garmentContext = { productName: PUBLIC_DRAFT.productName, description: "- 블랙 배색\n- 집업 재킷" };
  const sent = buildHeritageSearchRequest({ identification: brandOnly, garmentContext, preferBrandHeritage: true });
  const content = sent.input.flatMap(item => item.content ?? []);
  assert.equal(content.some(item => item.type === "input_image"), false);
  assert.equal(JSON.stringify(sent).includes(PNG), false);
  const input = JSON.parse(content.find(item => item.type === "input_text").text);
  assert.ok(JSON.stringify(input).includes(garmentContext.productName));
  assert.ok(JSON.stringify(input).includes("블랙 배색"));
  assert.match(input.searchQuery, /NIKE/);
  assert.match(input.searchQuery, /history|heritage/);
});

test("product-specific quoted release history is appended with a native source", () => {
  const research = parseHeritageSearchResponse(searchResponse(), IDENTIFICATION);
  assert.equal(research.matched, true);
  assert.equal(research.facts.length, 1);
  assert.equal(research.sources.length, 1);
  assert.equal(research.sources[0].url, SOURCE);
  const result = appendHeritageToDraft(PUBLIC_DRAFT, research);
  assert.equal(result.description, `${DRAFT.description}\n- 1998년 출시 모델`);
  assert.equal(result.productName, PUBLIC_DRAFT.productName);
  assert.equal(result.brand, PUBLIC_DRAFT.brand);
  assert.deepEqual(result.reviewNotes, PUBLIC_DRAFT.reviewNotes);
  assert.equal(result.description.includes(SOURCE), false);
  assert.equal(JSON.stringify(result).includes(FACT.supportingQuote), false);
});

test("meaningful official brand heritage is a natural paragraph without a label or bullet", async t => {
  const brandOnly = identification({ productCode: null, evidence: IDENTIFICATION.evidence.slice(0, 1) });
  for (const sourceKind of ["official_about", "official_history", "official_archive"]) {
    await t.test(sourceKind, () => {
      const fact = { ...BRAND_FACT, sourceKind,
        sentence: sourceKind === "official_about" ? `- ${BRAND_FACT.sentence}` : BRAND_FACT.sentence };
      const research = parseHeritageSearchResponse(searchResponse([fact], {
        sources: BRAND_SOURCES,
      }), brandOnly);
      assert.equal(research.matched, true);
      const result = appendHeritageToDraft(PUBLIC_DRAFT, research);
      assert.equal(result.description, `${PUBLIC_DRAFT.description}\n\n${BRAND_PARAGRAPH}`);
      assert.doesNotMatch(result.description, /브랜드\s*(?:배경|헤리티지)\s*:/);
      assert.equal(result.description.split("\n\n").at(-1).startsWith("- "), false);
      assert.deepEqual(result.sources.map(source => source.url), [BRAND_SOURCE]);
      assert.doesNotMatch(result.description, /1998|제조|출시/);
    });
  }
});

test("brand heritage rejects nonofficial, unrelated, uncited, or garment-dating evidence", async t => {
  const cases = [
    ...["retailer_product", "resale_listing", "official_product", "collection_catalog"].map(sourceKind =>
      [`source kind ${sourceKind}`, { ...BRAND_FACT, sourceKind }]),
    ["wrong brand", { ...BRAND_FACT, subjectBrand: "ADIDAS" }],
    ["wrong subject", { ...BRAND_FACT, subjectIdentifier: "123456-010" }],
    ["no quoted brand", { ...BRAND_FACT, supportingQuote: "A sportswear company expanded into daily apparel." }],
    ["partial quoted brand", { ...BRAND_FACT, supportingQuote: "SNIKEY began with sportswear." }],
    ["made-up URL", { ...BRAND_FACT, sourceUrl: "https://about.nike.com/en/not-returned" }],
    ["founding year as a fact field", { ...BRAND_FACT, yearStart: 1964 }],
    ["date hidden in prose", { ...BRAND_FACT, sentence: "NIKE는 1964년 출발한 스포츠웨어 브랜드입니다." }],
    ["garment manufacture claim", { ...BRAND_FACT, sentence: "NIKE는 오래전 제조된 빈티지 의류를 선보이는 브랜드입니다." }],
    ["authenticity claim", { ...BRAND_FACT, sentence: "NIKE는 브랜드 역사가 증명하는 정품 의류를 선보입니다." }],
    ["null heritage basis", { ...BRAND_FACT, heritageBasis: null }],
    ["unsupported heritage basis", { ...BRAND_FACT, heritageBasis: "brand_marketing" }],
    ["missing heritage basis", { ...BRAND_FACT, heritageBasis: undefined }],
    ["brand name missing from prose", { ...BRAND_FACT, sentence: "러닝에서 출발해 와플 아웃솔을 상징적인 디자인 전통으로 발전시킨 브랜드입니다." }],
    ["prose too long", { ...BRAND_FACT, sentence: `NIKE는 ${"고유 디자인 전통을 이어가는 ".repeat(15)}브랜드입니다.` }],
    ["unwanted brand-background label", { ...BRAND_FACT, sentence: `NIKE 브랜드 배경: ${BRAND_FACT.sentence}` }],
  ];
  for (const [name, fact] of cases) {
    await t.test(name, () => {
      const result = parseHeritageSearchResponse(searchResponse([fact], { sources: BRAND_SOURCES }), IDENTIFICATION);
      assert.equal(result.matched, false);
      assert.deepEqual(result.facts, []);
      assert.deepEqual(result.sources, []);
    });
  }
});

test("official brand R&D heritage allows material research and garment-making experimentation", async t => {
  for (const sentence of [RESEARCH_FACT.sentence,
    "STONE ISLAND는 의류 제작 실험을 상징적인 디자인 전통으로 발전시켜 온 브랜드입니다.",
    "STONE ISLAND는 소재와 염색 연구를 상징적인 디자인 전통으로 발전시켜 온 브랜드입니다."]) {
    await t.test(sentence, () => {
      const research = parseHeritageSearchResponse(searchResponse([{ ...RESEARCH_FACT, sentence }], { sources: [
        { title: "Synthetic official R&D history", url: RESEARCH_SOURCE },
      ] }), RESEARCH_BRAND);
      assert.equal(research.matched, true);
      const result = appendHeritageToDraft({ ...PUBLIC_DRAFT, brand: "STONE ISLAND" }, research);
      assert.ok(result.description.endsWith(`\n\n${sentence}`));
      assert.deepEqual(result.sources.map(source => source.url), [RESEARCH_SOURCE]);
    });
  }
});

test("brand R&D wording needs direct research support in the official quote", async t => {
  for (const sentence of [RESEARCH_FACT.sentence,
    "STONE ISLAND는 의류 제작 실험을 상징적인 디자인 전통으로 발전시켜 온 브랜드입니다."]) {
    await t.test(sentence, () => {
      const fact = { ...RESEARCH_FACT, sentence,
        supportingQuote: "STONE ISLAND offers jackets and other clothing through its stores." };
      const research = parseHeritageSearchResponse(searchResponse([fact], { sources: [
        { title: "Synthetic unrelated official page", url: RESEARCH_SOURCE },
      ] }), RESEARCH_BRAND);
      assert.equal(research.matched, false);
      assert.deepEqual(research.sources, []);
    });
  }
});

test("a valid research clause does not allow actual garment composition, performance, age, or value claims", async t => {
  const claims = [
    "소재 연구와 면 100% 구성", "소재 연구로 완성된 100% 울 니트", "소재 연구와 나일론 소재 구성", "소재 연구와 방수 성능을 갖춘 의류",
    "소재 연구를 통해 면으로 만든 니트", "소재 연구로 완성한 나일론 재킷", "캐시미어 소재 연구로 완성한 니트",
    "소재 연구로 확보한 높은 내구성", "소재 연구를 통해 이탈리아에서 제작한 재킷",
    "소재 연구로 이어진 90s 빈티지", "소재 연구로 확인되는 1998년 제조 의류",
    "소재 연구를 바탕으로 보장되는 정품", "소재 연구에서 비롯된 희소성",
  ];
  for (const sentence of claims) {
    await t.test(sentence, () => {
      const research = parseHeritageSearchResponse(searchResponse([{ ...RESEARCH_FACT, sentence: `STONE ISLAND는 ${sentence}입니다.` }], { sources: [
        { title: "Synthetic official R&D history", url: RESEARCH_SOURCE },
      ] }), RESEARCH_BRAND);
      assert.equal(research.matched, false);
      assert.deepEqual(research.facts, []);
      assert.deepEqual(research.sources, []);
    });
  }
});

test("brand founding history cannot become a garment release or manufacture year", () => {
  const brandOnly = identification({ productCode: null, evidence: IDENTIFICATION.evidence.slice(0, 1) });
  const foundingQuote = "NIKE was founded in 1964 and later expanded into everyday apparel.";
  for (const type of ["year_release", "year_manufacture"]) {
    const fact = { ...FACT, type, yearStart: 1964, sourceUrl: BRAND_SOURCE,
      subjectIdentifier: "NIKE", supportingQuote: foundingQuote, sourceKind: "official_history" };
    assert.equal(parseHeritageSearchResponse(searchResponse([fact], { sources: BRAND_SOURCES }), brandOnly).matched, false);
  }
  assert.equal(parseHeritageSearchResponse(searchResponse([FACT]), brandOnly).matched, false);
});

test("generic brand biography with no meaningful heritage basis is omitted after one search", async () => {
  const brandOnly = identification({ productCode: null, evidence: IDENTIFICATION.evidence.slice(0, 1) });
  const genericBio = { ...BRAND_FACT, heritageBasis: null,
    sentence: "NIKE는 스포츠웨어와 일상복을 판매하는 브랜드입니다.",
    supportingQuote: "NIKE sells sportswear and everyday apparel through its stores." };
  const h = workerHarness([baseline(brandOnly), searchResponse([genericBio], { sources: BRAND_SOURCES, nextQuery: "" })]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.description, PUBLIC_DRAFT.description);
  assert.equal(result.sources, undefined);
  assert.equal(result.description.includes(genericBio.sentence), false);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
  assert.equal(h.calls.length, 2);
});

test("a completed product match with no specific heritage follow-up does not force a second search", async () => {
  const h = workerHarness([baseline(), searchResponse([FACT], { nextQuery: "" })]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.description, `${PUBLIC_DRAFT.description}\n- 1998년 출시 모델`);
  assert.deepEqual(result.sources.map(source => source.url), [SOURCE]);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  assert.equal(h.calls.length, 2);
});

test("multiple accepted brand facts collapse into one final paragraph and one used source", () => {
  const anotherSource = "https://about.nike.com/en/fixture-about";
  const anotherBrandFact = { ...BRAND_FACT, sourceUrl: anotherSource, sourceKind: "official_about",
    sentence: "NIKE는 러닝의 유산을 와플 아웃솔이라는 상징적인 디자인 전통으로 이어 온 브랜드입니다." };
  const research = parseHeritageSearchResponse(searchResponse([BRAND_FACT, FACT, anotherBrandFact], { sources: [
    ...BRAND_SOURCES, { title: "Fixture product archive", url: SOURCE }, { title: "Fixture about", url: anotherSource },
  ] }), IDENTIFICATION);
  const result = appendHeritageToDraft(PUBLIC_DRAFT, research);
  assert.equal(research.facts.filter(fact => fact.type === "brand_heritage").length, 1);
  assert.equal(result.description, `${PUBLIC_DRAFT.description}\n- 1998년 출시 모델\n\n${BRAND_PARAGRAPH}`);
  assert.deepEqual(new Set(result.sources.map(source => source.url)), new Set([SOURCE, BRAND_SOURCE]));
});

test("unrelated products, absent evidence, and fabricated links cannot become history", async t => {
  const cases = [
    ["wrong brand", { ...FACT, subjectBrand: "ADIDAS" }],
    ["wrong model", { ...FACT, subjectIdentifier: "654321-100" }],
    ["brand history only", { ...FACT, subjectIdentifier: "NIKE", supportingQuote: "NIKE was founded in 1964." }],
    ["no quoted product", { ...FACT, supportingQuote: "This NIKE jacket was released in 1998." }],
    ["partial product code", { ...FACT, supportingQuote: "NIKE 9123456-0109 was released in 1998." }],
    ...["123456-010-RED", "RED-123456-010", "123456-010_RED", "123456-010.RED"].map(code =>
      [`different complete code ${code}`, { ...FACT, supportingQuote: `NIKE ${code} was released in 1998.` }]),
    ["no quoted year", { ...FACT, supportingQuote: "NIKE 123456-010 is a jacket." }],
    ["invented year", { ...FACT, yearStart: 1999 }],
    ["invented source", { ...FACT, sourceUrl: "https://www.nike.com/t/not-in-native-search" }],
    ["unsafe source", { ...FACT, sourceUrl: "https://localhost/private" }],
    ["resale dates", { ...FACT, sourceKind: "resale_listing" }],
    ["retailer dates", { ...FACT, sourceKind: "retailer_product" }],
    ["product facts cannot borrow a brand heritage basis", { ...FACT, heritageBasis: "signature_tradition" }],
  ];
  for (const [name, fact] of cases) {
    await t.test(name, () => {
      const result = parseHeritageSearchResponse(searchResponse([fact]), IDENTIFICATION);
      assert.equal(result.matched, false);
      assert.deepEqual(result.facts, []);
      assert.deepEqual(result.sources, []);
      assert.deepEqual(appendHeritageToDraft(PUBLIC_DRAFT, result), PUBLIC_DRAFT);
    });
  }
});

test("release sources never establish a specimen manufacture year", () => {
  const fact = { ...FACT, type: "year_manufacture", supportingQuote: "NIKE 123456-010 was manufactured in 1998." };
  const result = parseHeritageSearchResponse(searchResponse([fact]), IDENTIFICATION);
  assert.equal(result.matched, false);
  assert.deepEqual(result.facts, []);
});

test("manufacture year needs both photographed date evidence and an agreeing product-specific source", () => {
  const dated = identification({ manufactureYear: 1998, evidence: [
    ...IDENTIFICATION.evidence,
    { kind: "manufacture_date", text: "Manufactured 1998", photoId: "label-1", confidence: "high" },
  ] });
  const parsed = parseIdentificationResponse(baseline(dated), PHOTOS);
  const fact = { ...FACT, type: "year_manufacture", supportingQuote: "NIKE 123456-010 was manufactured in 1998." };
  const research = parseHeritageSearchResponse(searchResponse([fact]), parsed.identification);
  assert.equal(research.matched, true);
  const result = appendHeritageToDraft(PUBLIC_DRAFT, research);
  assert.match(result.description, /\n- 1998년.*제조/);
  assert.doesNotMatch(result.description, /출시/);
  const mismatch = { ...fact, yearStart: 1999, supportingQuote: "NIKE 123456-010 was manufactured in 1999." };
  assert.equal(parseHeritageSearchResponse(searchResponse([mismatch]), parsed.identification).matched, false);
});

test("release years are rendered as model release history rather than arbitrary model-authored claims", () => {
  const fact = { ...FACT, sentence: "1998년 제조 정품이며 방수 기능과 높은 희소성을 보장합니다." };
  const research = parseHeritageSearchResponse(searchResponse([fact]), IDENTIFICATION);
  const result = appendHeritageToDraft(PUBLIC_DRAFT, research);
  assert.match(result.description, /1998/);
  assert.doesNotMatch(result.description, /정품|방수|보장|제조/);
});

test("a supported release range is one short release bullet and never a manufacture claim", () => {
  const fact = { ...FACT, yearEnd: 2000,
    supportingQuote: "NIKE 123456-010 was released across the 1998 through 2000 collections." };
  const research = parseHeritageSearchResponse(searchResponse([fact]), IDENTIFICATION);
  const result = appendHeritageToDraft(PUBLIC_DRAFT, research);
  assert.equal(result.description, `${PUBLIC_DRAFT.description}\n- 1998~2000년 출시 모델`);
  assert.doesNotMatch(result.description, /제조/);
});

test("product-specific design history may use an identified retailer page without adding a year", () => {
  const fact = { ...FACT, type: "design_history", yearStart: null, yearEnd: null,
    sentence: "- 훈련용 재킷에서 이어진 배색 구성",
    supportingQuote: "NIKE 123456-010 adopts the contrasting panel design of its training jacket line.",
    sourceKind: "retailer_product" };
  const research = parseHeritageSearchResponse(searchResponse([fact]), IDENTIFICATION);
  assert.equal(research.matched, true);
  const result = appendHeritageToDraft(PUBLIC_DRAFT, research);
  assert.ok(result.description.endsWith("\n- 훈련용 재킷에서 이어진 배색 구성"));
  assert.doesNotMatch(result.description, /-\s*-/);
  assert.doesNotMatch(result.description, /1998/);
  assert.equal(result.sources.length, 1);
});

test("history prose cannot smuggle dates or specimen manufacture claims outside date fields", async t => {
  for (const sentence of ["1998년에 출시된 훈련용 재킷입니다.", "1990年 컬렉션에서 선보인 디자인입니다.",
    "90s 컬렉션의 배색 구성이 특징입니다.", "생산된 당시의 패널 구성을 유지한 모델입니다.", "제조된 제품의 배색 구성이 특징입니다."]) {
    await t.test(sentence, () => {
      const fact = { ...FACT, type: "design_history", yearStart: null, yearEnd: null,
        sentence, supportingQuote: "NIKE 123456-010 uses a contrasting training jacket design." };
      assert.equal(parseHeritageSearchResponse(searchResponse([fact]), IDENTIFICATION).matched, false);
    });
  }
});

test("history is omitted together with its sources when the existing description is already at its limit", () => {
  const draft = { ...PUBLIC_DRAFT, description: "가".repeat(1200) };
  const research = parseHeritageSearchResponse(searchResponse(), IDENTIFICATION);
  assert.deepEqual(appendHeritageToDraft(draft, research), draft);
});

test("heritage list appends honor the exact description limit and only retain sources for lines that fit", () => {
  const secondSource = "https://www.nike.com/t/fixture-history-123456-010";
  const history = { ...FACT, type: "design_history", yearStart: null, yearEnd: null,
    sentence: "훈련복의 배색 절개를 계승한 디자인", sourceUrl: secondSource,
    supportingQuote: "NIKE 123456-010 adopts the contrasting panel design of its training jacket line." };
  const research = parseHeritageSearchResponse(searchResponse([FACT, history], { sources: [
    { title: "Fixture release archive", url: SOURCE }, { title: "Fixture design archive", url: secondSource },
  ] }), IDENTIFICATION);
  const releaseLine = "- 1998년 출시 모델";
  const fits = { ...PUBLIC_DRAFT, description: "가".repeat(1200 - releaseLine.length - 1) };
  const result = appendHeritageToDraft(fits, research);
  assert.equal(result.description.length, 1200);
  assert.ok(result.description.endsWith(`\n${releaseLine}`));
  assert.deepEqual(result.sources.map(source => source.url), [SOURCE]);
  assert.equal(result.description.includes(history.sentence), false);
  const tooLong = { ...fits, description: `${fits.description}가` };
  assert.deepEqual(appendHeritageToDraft(tooLong, research), tooLong);
});

test("the description budget reserves room for brand heritage before optional product facts", () => {
  const research = parseHeritageSearchResponse(searchResponse([FACT, BRAND_FACT], { sources: [
    { title: "Fixture product archive", url: SOURCE }, ...BRAND_SOURCES,
  ] }), IDENTIFICATION);
  const draft = { ...PUBLIC_DRAFT, description: "가".repeat(1200 - BRAND_PARAGRAPH.length - 2) };
  const result = appendHeritageToDraft(draft, research);
  assert.equal(result.description, `${draft.description}\n\n${BRAND_PARAGRAPH}`);
  assert.equal(result.description.length, 1200);
  assert.deepEqual(result.sources.map(source => source.url), [BRAND_SOURCE]);
  assert.equal(result.description.includes("1998"), false);
});

test("an oversized heritage paragraph never truncates the photo draft or adds an unused brand source", () => {
  const research = parseHeritageSearchResponse(searchResponse([FACT, BRAND_FACT], { sources: [
    { title: "Fixture product archive", url: SOURCE }, ...BRAND_SOURCES,
  ] }), IDENTIFICATION);
  const productLine = "- 1998년 출시 모델";
  const draft = { ...PUBLIC_DRAFT, description: "가".repeat(1200 - productLine.length - 1) };
  const result = appendHeritageToDraft(draft, research);
  assert.equal(result.description, `${draft.description}\n${productLine}`);
  assert.equal(result.description.length, 1200);
  assert.deepEqual(result.sources.map(source => source.url), [SOURCE]);
  assert.equal(result.description.includes(BRAND_PARAGRAPH), false);
});

test("unsafe native URLs do not become public links even when the model repeats them", async t => {
  for (const url of ["http://www.nike.com/archive", "https://localhost/archive", "https://127.0.0.1/archive",
    "https://user:password@www.nike.com/archive", "https://archive.internal/item", "javascript:alert(1)"]) {
    await t.test(url, () => {
      const result = parseHeritageSearchResponse(searchResponse([{ ...FACT, sourceUrl: url }], {
        sources: [{ url, title: "Unsafe fixture" }],
      }), IDENTIFICATION);
      assert.equal(result.matched, false);
      assert.deepEqual(result.sources, []);
    });
  }
});

test("missing, failed, incomplete, excess, or non-search tool calls are rejected", async t => {
  const call = { type: "web_search_call", status: "completed", action: { type: "search", query: "fixture", sources: [] } };
  const cases = [
    ["missing call", []],
    ["failed call", [{ ...call, status: "failed" }]],
    ["incomplete call", [{ ...call, status: "in_progress" }]],
    ["more than one call", [call, call]],
    ["open page only", [{ ...call, action: { type: "open_page", url: SOURCE } }]],
  ];
  for (const [name, calls] of cases) {
    await t.test(name, () => {
      assert.throws(() => parseHeritageSearchResponse(searchResponse([], { calls }), IDENTIFICATION));
    });
  }
});

test("the photo-only stage rejects unexpected native tools and research rejects non-web tools", () => {
  const photoPayload = baseline();
  photoPayload.output.unshift({ type: "web_search_call", status: "completed", action: { type: "search", query: "unexpected" } });
  assert.throws(() => parseIdentificationResponse(photoPayload, PHOTOS));
  const research = searchResponse();
  research.output.unshift({ type: "function_call", name: "unapproved_tool", arguments: "{}", call_id: "fixture-call" });
  assert.throws(() => parseHeritageSearchResponse(research, IDENTIFICATION));
});

test("search commentary is never parsed as final JSON or used as source provenance", () => {
  const response = searchResponse();
  response.output.unshift({ type: "message", role: "assistant", phase: "commentary", content: [
    { type: "output_text", text: "사진 라벨의 제품 코드를 검색하겠습니다.", annotations: [
      { type: "url_citation", title: "Unrelated commentary", url: "https://unrelated.example.org/page", start_index: 0, end_index: 3 },
    ] },
  ] });
  const result = parseHeritageSearchResponse(response, IDENTIFICATION);
  assert.equal(result.matched, true);
  assert.deepEqual(result.sources.map(item => item.url), [SOURCE]);
  const invented = searchResponse([FACT], { sources: [] });
  invented.output.unshift({ type: "message", role: "assistant", phase: "commentary", content: [
    { type: "output_text", text: "이 페이지를 확인할 예정입니다.", annotations: [
      { type: "url_citation", title: "Not actually searched", url: SOURCE, start_index: 0, end_index: 3 },
    ] },
  ] });
  assert.equal(parseHeritageSearchResponse(invented, IDENTIFICATION).matched, false);
});

test("refused or incomplete research cannot supply successful history", async t => {
  const refusal = searchResponse();
  refusal.output.push({ type: "message", role: "assistant", phase: "final_answer", content: [
    { type: "refusal", refusal: "private-refusal-detail" },
  ] });
  for (const [name, response] of [["refusal", refusal], ["incomplete response", { ...searchResponse(), status: "incomplete" }]]) {
    await t.test(name, () => assert.throws(() => parseHeritageSearchResponse(response, IDENTIFICATION)));
  }
});

test("pipeline stops after the first accepted brand heritage and exposes no internal evidence", async () => {
  const h = workerHarness([baseline(), searchResponse([BRAND_FACT], { sources: BRAND_SOURCES })]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(h.calls.length, 2);
  assert.ok(result.description.endsWith(`\n\n${BRAND_PARAGRAPH}`));
  assert.equal(result.brand, PUBLIC_DRAFT.brand);
  assert.equal(result.productName, PUBLIC_DRAFT.productName);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  assert.deepEqual(Object.keys(result).sort(), ["brand", "description", "productName", "reviewNotes", "sources"]);
  assert.equal(JSON.stringify(result).includes("supportingQuote"), false);
  assert.equal(JSON.stringify(result).includes("identification"), false);
});

test("pipeline refines an unmatched search once and never exceeds two search attempts", async () => {
  const h = workerHarness([baseline(), searchResponse([], { nextQuery: "NIKE 123456-010 official archive" }),
    searchResponse([BRAND_FACT], { sources: BRAND_SOURCES })]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  assert.equal(h.calls.length, 3);
  assert.equal(h.calls.filter(call => call.body.tools?.some(tool => tool.type === "web_search")).length, 2);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  const secondInput = JSON.parse(h.calls[2].body.input[0].content[0].text);
  assert.match(secondInput.searchQuery, /NIKE/);
  assert.equal(secondInput.preferBrandHeritage, true);
  assert.equal(secondInput.previousQuery, "NIKE 123456-010");
});

test("a first product year is retained while the second search adds a separate heritage paragraph", async () => {
  const h = workerHarness([baseline(), searchResponse(), searchResponse([BRAND_FACT], { sources: BRAND_SOURCES })]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.description, `${PUBLIC_DRAFT.description}\n- 1998년 출시 모델\n\n${BRAND_PARAGRAPH}`);
  assert.deepEqual(new Set(result.sources.map(source => source.url)), new Set([SOURCE, BRAND_SOURCE]));
  assert.equal(h.calls.length, 3);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "2");
  const followUp = JSON.parse(h.calls[2].body.input[0].content[0].text);
  assert.equal(followUp.preferBrandHeritage, true);
});

test("two product facts reserve the third research slot for brand heritage and drop unused sources", async () => {
  const manufactureSource = "https://www.nike.com/t/fixture-manufacture-123456-010";
  const designSource = "https://www.nike.com/t/fixture-design-123456-010";
  const datedIdentity = identification({ manufactureYear: 1998, evidence: [
    ...IDENTIFICATION.evidence,
    { kind: "manufacture_date", text: "Manufactured 1998", photoId: "label-1", confidence: "high" },
  ] });
  const manufacture = { ...FACT, type: "year_manufacture", sourceUrl: manufactureSource,
    supportingQuote: "NIKE 123456-010 was manufactured in 1998." };
  const design = { ...FACT, type: "design_history", yearStart: null, yearEnd: null, sourceUrl: designSource,
    sentence: "훈련복의 배색 절개를 계승한 디자인",
    supportingQuote: "NIKE 123456-010 adopts the contrasting panel design of its training jacket line." };
  const h = workerHarness([baseline(datedIdentity), searchResponse([FACT, manufacture, design], { sources: [
    { title: "Fixture release", url: SOURCE }, { title: "Fixture manufacture", url: manufactureSource },
    { title: "Fixture design", url: designSource },
  ] }), searchResponse([BRAND_FACT], { sources: BRAND_SOURCES })]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.description, `${PUBLIC_DRAFT.description}\n- 1998년 출시 모델\n- 1998년 제조 제품\n\n${BRAND_PARAGRAPH}`);
  assert.equal(result.description.includes(design.sentence), false);
  assert.equal(result.sources.length, 3);
  assert.deepEqual(new Set(result.sources.map(source => source.url)), new Set([SOURCE, manufactureSource, BRAND_SOURCE]));
  assert.equal(h.calls.length, 3);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
});

test("a second no-match preserves accepted product facts and their sources without a third search", async () => {
  const h = workerHarness([baseline(), searchResponse(), searchResponse([])]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.description, `${PUBLIC_DRAFT.description}\n- 1998년 출시 모델`);
  assert.deepEqual(result.sources.map(source => source.url), [SOURCE]);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  assert.equal(h.calls.length, 3);
});

test("second-search transport failure preserves first-search facts while reporting incomplete research", async () => {
  const h = workerHarness([baseline(), searchResponse(), () => { throw new Error("private-second-search-error test-key"); }]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.description, `${PUBLIC_DRAFT.description}\n- 1998년 출시 모델`);
  assert.deepEqual(result.sources.map(source => source.url), [SOURCE]);
  assert.ok(result.reviewNotes.some(note => /완료하지 못/.test(note)));
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "incomplete");
  assert.equal(h.calls.length, 3);
});

test("two unrelated searches return the original photo draft with no unrelated sources", async () => {
  const h = workerHarness([baseline(), searchResponse([]), searchResponse([])]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  assert.equal(h.calls.length, 3);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
  assertPhotoOnly(await response.json(), /확인하지 못/);
});

test("search transport failure preserves a valid photo draft without another paid attempt", async () => {
  const h = workerHarness([baseline(), () => { throw new Error("private-search-error test-key"); }]);
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "incomplete");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "0");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "1");
  assertPhotoOnly(await response.json(), /완료하지 못/);
  assert.equal(h.calls.length, 2);
});

test("research timeout cancels the search and retains the valid photo-only result", async () => {
  let aborted = false;
  const h = workerHarness([baseline(), init => new Promise((_resolve, reject) => {
    init.signal.addEventListener("abort", () => {
      aborted = true;
      reject(new DOMException("private-research-timeout", "AbortError"));
    }, { once: true });
  })], { timeoutMs: 20 });
  const response = await h.worker.fetch(photoRequest(), h.env);
  assert.equal(response.status, 200);
  assert.equal(aborted, true);
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "incomplete");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "0");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "1");
  assertPhotoOnly(await response.json(), /완료하지 못/);
  assert.equal(h.calls.length, 2);
});

test("malformed research or missing native search is an error instead of a claimed search success", async t => {
  for (const [name, value] of [["missing native search", searchResponse([], { calls: [] })],
    ["malformed facts", searchResponse("not-an-array")]]) {
    await t.test(name, async () => {
      const h = workerHarness([baseline(), value]);
      const response = await h.worker.fetch(photoRequest(), h.env);
      assert.equal(response.status, 502);
      const text = await response.text();
      assert.equal(text.includes("test-key"), false);
      assert.equal(text.includes(PNG), false);
      assert.equal(h.calls.length, 2);
    });
  }
});
