import test from "node:test";
import assert from "node:assert/strict";
import { createWorker } from "../src/index.js";

// These injected photos, products, quotes, and URLs are synthetic fixtures.
// No test searches the network or calls a paid model.
const PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=";
const PHOTOS = ["label-1", "label-2"].map(id => ({ id, role: "label", imageDataUrl: PNG }));
const DRAFT = {
  brand: { originalName: "NIKE", localizedName: "나이키" },
  productNameWithoutBrand: "블랙 배색 집업 재킷",
  description: "- 블랙 바탕의 입체적인 배색\n- 겹쳐진 패널의 스포티한 무드",
  reviewNotes: [],
};
const IDENTITY = {
  brand: "NIKE", productCode: null, modelName: null, manufactureYear: null,
  evidence: [{ kind: "brand_label", text: "NIKE × sacai", photoId: "label-1", confidence: "high" }],
};
const CANDIDATE = {
  participants: [
    { originalName: "NIKE", localizedName: "나이키", photoId: "label-1", labelText: "NIKE × sacai", confidence: "high" },
    { originalName: "sacai", localizedName: "사카이", photoId: "label-1", labelText: "NIKE × sacai", confidence: "high" },
  ],
  relationshipEvidence: [{ photoId: "label-1", text: "NIKE × sacai", confidence: "high" }],
};
const SOURCE = "https://www.nike.com/launch/t/fixture-nike-sacai";
const COLLABORATION = {
  participantNames: ["NIKE", "sacai"], sourceUrl: SOURCE,
  sourceKind: "official_product", subjectIdentifier: null,
  supportingQuote: "NIKE and sacai created this collaboration with a joint NIKE × sacai label.",
};

function assistant(value) {
  return { type: "message", role: "assistant", phase: "final_answer", content: [
    { type: "output_text", text: JSON.stringify(value), annotations: [] },
  ] };
}

function baseline({ candidate = CANDIDATE, identity = IDENTITY, draft = DRAFT, legacy = false } = {}) {
  return { status: "completed", output: [assistant({
    ...draft, identification: identity, ...(legacy ? {} : { collaborationCandidate: candidate }),
  })] };
}

function research({ collaboration = COLLABORATION, facts = [], nextQuery = "", sources = [{ title: "Fixture official collaboration", url: SOURCE }],
  legacy = false, calls = null } = {}) {
  return { status: "completed", output: [
    ...(calls ?? [{ type: "web_search_call", status: "completed", action: {
      type: "search", query: "NIKE sacai collaboration", sources,
    } }]),
    assistant({ facts, nextQuery, ...(legacy ? {} : { collaboration }) }),
  ] };
}

function harness(responses, options = {}) {
  const calls = [];
  const worker = createWorker({ ...options, fetchImpl: async (url, init) => {
    // This suite isolates research/collaboration behavior; readback is covered
    // separately with explicit competing-label responses in brand-discovery.
    if (JSON.parse(init.body).text?.format?.name === "garment_brand_readback") {
      return Response.json({ status: "completed", output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: JSON.stringify({ brand: null }) }] }] });
    }
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    const value = responses[calls.length - 1];
    assert.notEqual(value, undefined, "unexpected additional model request");
    return typeof value === "function" ? value(init) : Response.json(value);
  } });
  return { worker, calls, env: { DRAFT_API_TOKEN: "fixture-token", OPENAI_API_KEY: "fixture-key" } };
}

function request() {
  return new Request("https://worker.example/v1/garments/autofill", {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer fixture-token" },
    body: JSON.stringify({ photos: PHOTOS }),
  });
}

function searchInput(call) {
  const text = call.body.input.flatMap(message => message.content ?? []).find(part => part.type === "input_text");
  return JSON.parse(text.text);
}

function assertOriginalDraft(value, draft = DRAFT) {
  const original = draft.brand.originalName;
  const localized = draft.brand.localizedName;
  assert.equal(value.brand, localized && localized !== original ? `${original} (${localized})` : original);
  assert.equal(value.productName, `${localized || original} ${draft.productNameWithoutBrand}`);
  assert.equal(value.description, draft.description);
  assert.equal(value.sources, undefined);
}

test("verified joint-label collaboration updates the brand and title through the existing single search", async () => {
  const h = harness([baseline(), research()]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.productName, "나이키 × 사카이 블랙 배색 집업 재킷");
  assert.equal(value.description, DRAFT.description);
  assert.deepEqual(value.sources, [{ title: "Fixture official collaboration", url: SOURCE }]);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  assert.equal(h.calls.length, 2);
  const search = h.calls[1].body;
  assert.deepEqual(search.tools.map(tool => tool.type), ["web_search"]);
  assert.equal(search.tool_choice, "required");
  assert.equal(search.max_tool_calls, 1);
  const input = searchInput(h.calls[1]);
  assert.ok(input.collaborationCandidate);
  assert.match(input.searchQuery, /NIKE/);
  assert.match(input.searchQuery, /sacai/);
  assert.match(input.searchQuery, /collab|협업|콜라보/iu);
  assert.deepEqual(Object.keys(value).sort(), ["brand", "description", "productName", "reviewNotes", "sources"]);
  assert.equal(JSON.stringify(value).includes("supportingQuote"), false);
  assert.equal(JSON.stringify(value).includes("collaborationCandidate"), false);
});

test("three photographed collaboration participants survive in their photographed order", async () => {
  const joint = "NIKE × sacai × fragment design";
  const candidate = {
    participants: [...CANDIDATE.participants.map(participant => ({ ...participant, labelText: joint })),
      { originalName: "fragment design", localizedName: "프라그먼트", photoId: "label-1", labelText: joint, confidence: "high" }],
    relationshipEvidence: [{ photoId: "label-1", text: joint, confidence: "high" }],
  };
  const collaboration = { ...COLLABORATION,
    participantNames: ["NIKE", "sacai", "fragment design"],
    supportingQuote: "NIKE, sacai and fragment design collaborated on this joint-label collaboration.",
  };
  const h = harness([baseline({ candidate }), research({ collaboration })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai × fragment design");
  assert.equal(value.productName, "나이키 × 사카이 × 프라그먼트 블랙 배색 집업 재킷");
  assert.equal(value.sources[0].url, SOURCE);
  assert.equal(h.calls.length, 2);
});

test("a valid photographed collaboration candidate remains searchable when the separate identification is null", async () => {
  const h = harness([baseline({ identity: null }), research()]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.productName, "나이키 × 사카이 블랙 배색 집업 재킷");
  const input = searchInput(h.calls[1]);
  assert.equal(input.identification.brand, "NIKE");
  assert.equal(input.identification.productCode, null);
  assert.equal(input.identification.modelName, null);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  assert.equal(h.calls.length, 2);
});

test("the collaboration prefix replaces an accidentally repeated primary brand without losing the product name", async () => {
  const draft = { ...DRAFT, productNameWithoutBrand: "NIKE 나이키 블랙 배색 집업 재킷" };
  const h = harness([baseline({ draft }), research()]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.productName, "나이키 × 사카이 블랙 배색 집업 재킷");
});

test("an exact photographed product code can connect separately photographed participant labels", async () => {
  const productCode = "FIX12345-010";
  const candidate = { participants: [
    { ...CANDIDATE.participants[0], labelText: "NIKE" },
    { ...CANDIDATE.participants[1], photoId: "label-2", labelText: "sacai" },
  ], relationshipEvidence: [] };
  const identity = { ...IDENTITY, productCode, evidence: [
    { kind: "brand_label", text: "NIKE", photoId: "label-1", confidence: "high" },
    { kind: "product_code", text: productCode, photoId: "label-1", confidence: "high" },
  ] };
  const collaboration = { ...COLLABORATION, subjectIdentifier: productCode,
    supportingQuote: `NIKE and sacai released the collaboration product ${productCode}.`,
  };
  const h = harness([baseline({ candidate, identity }), research({ collaboration })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.productName, "나이키 × 사카이 블랙 배색 집업 재킷");
  const query = searchInput(h.calls[1]).searchQuery;
  assert.ok(query.includes(productCode));
  assert.match(query, /NIKE/);
  assert.match(query, /sacai/);
  assert.equal(h.calls.length, 2);
});

test("the three-source budget keeps the collaboration and heritage sources before a second product fact", async () => {
  const productCode = "FIX12345-010";
  const releaseSource = "https://www.nike.com/fixture-release-archive";
  const manufactureSource = "https://www.nike.com/fixture-manufacture-archive";
  const heritageSource = "https://about.nike.com/fixture-design-heritage";
  const identity = { ...IDENTITY, productCode, manufactureYear: 1999, evidence: [
    ...IDENTITY.evidence,
    { kind: "product_code", text: productCode, photoId: "label-1", confidence: "high" },
    { kind: "manufacture_date", text: "Manufactured 1999", photoId: "label-1", confidence: "high" },
  ] };
  const facts = [
    { type: "year_release", yearStart: 1998, yearEnd: null, sentence: "",
      sourceUrl: releaseSource, sourceKind: "official_archive", subjectBrand: "NIKE", subjectIdentifier: productCode,
      supportingQuote: `NIKE ${productCode} was first released in 1998.`, heritageBasis: null },
    { type: "year_manufacture", yearStart: 1999, yearEnd: null, sentence: "",
      sourceUrl: manufactureSource, sourceKind: "official_archive", subjectBrand: "NIKE", subjectIdentifier: productCode,
      supportingQuote: `NIKE ${productCode} was manufactured in 1999.`, heritageBasis: null },
    { type: "brand_heritage", yearStart: null, yearEnd: null,
      sentence: "NIKE는 러닝의 유산을 와플 아웃솔이라는 상징적인 디자인 전통으로 이어 온 브랜드입니다.",
      sourceUrl: heritageSource, sourceKind: "official_history", subjectBrand: "NIKE", subjectIdentifier: "NIKE",
      supportingQuote: "NIKE's running heritage established the waffle outsole as a lasting signature design tradition.",
      heritageBasis: "signature_tradition" },
  ];
  const sources = [
    { title: "Fixture official collaboration", url: SOURCE },
    { title: "Fixture release archive", url: releaseSource },
    { title: "Fixture manufacture archive", url: manufactureSource },
    { title: "Fixture design heritage", url: heritageSource },
  ];
  const collaboration = { ...COLLABORATION, subjectIdentifier: productCode,
    supportingQuote: `NIKE and sacai released the collaboration product ${productCode}.`,
  };
  const h = harness([baseline({ identity }), research({ collaboration, facts, sources })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.description, `${DRAFT.description}\n- 1998년 출시 모델\n\n${facts[2].sentence}`);
  assert.deepEqual(new Set(value.sources.map(source => source.url)), new Set([SOURCE, releaseSource, heritageSource]));
  assert.equal(value.sources.length, 3);
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  assert.equal(h.calls.length, 2);
});

test("unproven collaboration results never replace the photo-based identity", async t => {
  const cases = [
    ["invented additional participant", { ...COLLABORATION, participantNames: ["NIKE", "sacai", "Supreme"],
      supportingQuote: "NIKE, sacai and Supreme collaborated on this garment." }],
    ["missing photographed participant", { ...COLLABORATION, participantNames: ["NIKE"] }],
    ["quote does not establish partnership", { ...COLLABORATION, supportingQuote: "NIKE and sacai are brands stocked by the store." }],
    ["quote omits one participant", { ...COLLABORATION, supportingQuote: "NIKE released this collaboration product." }],
    ["source was not returned by the search", { ...COLLABORATION, sourceUrl: "https://www.nike.com/launch/t/fixture-invented" }],
    ["resale post is not an official partnership source", { ...COLLABORATION, sourceKind: "resale_listing" }],
  ];
  for (const [name, collaboration] of cases) {
    await t.test(name, async () => {
      const h = harness([baseline(), research({ collaboration })]);
      const response = await h.worker.fetch(request(), h.env);
      assert.equal(response.status, 200);
      assertOriginalDraft(await response.json());
      assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
      assert.equal(h.calls.length, 2);
    });
  }
});

test("a model-authored URL without native source provenance cannot certify collaboration", async () => {
  const h = harness([baseline(), research({ sources: [] })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  assertOriginalDraft(await response.json());
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
});

test("historical partnership alone cannot identify a product without joint-label or exact-code evidence", async t => {
  const candidate = { participants: [
    { ...CANDIDATE.participants[0], labelText: "NIKE" },
    { ...CANDIDATE.participants[1], photoId: "label-2", labelText: "sacai" },
  ], relationshipEvidence: [] };
  for (const [name, identity, collaboration] of [
    ["no photographed joint label or product code", IDENTITY, COLLABORATION],
    ["product code never appears in quote", { ...IDENTITY, productCode: "FIX12345-010", evidence: [
      ...IDENTITY.evidence, { kind: "product_code", text: "FIX12345-010", photoId: "label-1", confidence: "high" },
    ] }, { ...COLLABORATION, subjectIdentifier: "FIX12345-010" }],
    ["different collaboration product code", { ...IDENTITY, productCode: "FIX12345-010", evidence: [
      ...IDENTITY.evidence, { kind: "product_code", text: "FIX12345-010", photoId: "label-1", confidence: "high" },
    ] }, { ...COLLABORATION, subjectIdentifier: "FIX12345-020", supportingQuote: "NIKE and sacai collaboration FIX12345-020." }],
  ]) {
    await t.test(name, async () => {
      const h = harness([baseline({ candidate, identity }), research({ collaboration })]);
      const response = await h.worker.fetch(request(), h.env);
      assert.equal(response.status, 200);
      assertOriginalDraft(await response.json());
      assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
    });
  }
});

test("a low-confidence or unavailable participant photo cannot be promoted by search", async t => {
  for (const [name, changedParticipant] of [
    ["uncertain label", { ...CANDIDATE.participants[1], confidence: "medium" }],
    ["photo not submitted", { ...CANDIDATE.participants[1], photoId: "unavailable-photo" }],
    ["participant absent from its label text", { ...CANDIDATE.participants[1], labelText: "unreadable lettering" }],
  ]) {
    await t.test(name, async () => {
      const candidate = { ...CANDIDATE, participants: [CANDIDATE.participants[0], changedParticipant] };
      const h = harness([baseline({ candidate }), research()]);
      const response = await h.worker.fetch(request(), h.env);
      assert.equal(response.status, 200);
      assertOriginalDraft(await response.json());
      assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
    });
  }
});

test("a parent brand and its label are not reclassified as a collaboration", async () => {
  const draft = { ...DRAFT, brand: { originalName: "Ralph Lauren", localizedName: "랄프로렌" } };
  const identity = { ...IDENTITY, brand: "Ralph Lauren", evidence: [
    { kind: "brand_label", text: "Ralph Lauren", photoId: "label-1", confidence: "high" },
  ] };
  const candidate = { participants: [
    { originalName: "Ralph Lauren", localizedName: "랄프로렌", photoId: "label-1", labelText: "Ralph Lauren", confidence: "high" },
    { originalName: "RRL", localizedName: "더블알엘", photoId: "label-2", labelText: "RRL", confidence: "high" },
  ], relationshipEvidence: [] };
  const sourceUrl = "https://www.ralphlauren.com/fixture-label-profile";
  const collaboration = { participantNames: ["Ralph Lauren", "RRL"], sourceUrl,
    sourceKind: "official_archive", subjectIdentifier: null,
    supportingQuote: "RRL is a label created by Ralph Lauren.",
  };
  const h = harness([baseline({ candidate, identity, draft }), research({ collaboration,
    sources: [{ title: "Fixture official label profile", url: sourceUrl }] })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  assertOriginalDraft(await response.json(), draft);
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
});

test("legacy photo and search responses remain valid without collaboration fields", async () => {
  const h = harness([baseline({ legacy: true }), research({ legacy: true })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  assertOriginalDraft(await response.json());
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(h.calls.length, 2);
});

test("collaboration research remains within the shared two-search limit", async () => {
  const nextQuery = "NIKE sacai collaboration official archive";
  const h = harness([baseline(), research({ collaboration: null, nextQuery }), research({ nextQuery })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.productName, "나이키 × 사카이 블랙 배색 집업 재킷");
  assert.equal(h.calls.length, 3);
  assert.equal(h.calls.filter(call => call.body.tools?.some(tool => tool.type === "web_search")).length, 2);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
  assert.equal(searchInput(h.calls[2]).searchQuery, nextQuery);
});

test("unmatched collaboration searches retain the original draft without a third attempt", async () => {
  const nextQuery = "NIKE sacai collaboration official archive";
  const h = harness([baseline(), research({ collaboration: null, nextQuery }), research({ collaboration: null, nextQuery })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  assertOriginalDraft(await response.json());
  assert.equal(h.calls.length, 3);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "no_match");
});

test("a later empty search preserves the already verified collaboration and its source", async () => {
  const nextQuery = "NIKE sacai collaboration official archive";
  const h = harness([baseline(), research({ nextQuery }), research({ collaboration: null })]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.productName, "나이키 × 사카이 블랙 배색 집업 재킷");
  assert.deepEqual(value.sources.map(source => source.url), [SOURCE]);
  assert.equal(h.calls.length, 3);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "matched");
});

test("a later search transport failure retains the verified collaboration while reporting incomplete research", async () => {
  const nextQuery = "NIKE sacai collaboration official archive";
  const h = harness([baseline(), research({ nextQuery }), () => { throw new Error("synthetic-transport-failure"); }]);
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.brand, "NIKE × sacai");
  assert.equal(value.productName, "나이키 × 사카이 블랙 배색 집업 재킷");
  assert.deepEqual(value.sources.map(source => source.url), [SOURCE]);
  assert.equal(h.calls.length, 3);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "2");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "incomplete");
});

test("collaboration search timeout preserves the photo draft and does not retry automatically", async () => {
  let aborted = false;
  const h = harness([baseline(), init => new Promise((_resolve, reject) => {
    init.signal.addEventListener("abort", () => {
      aborted = true;
      reject(new DOMException("synthetic-search-timeout", "AbortError"));
    }, { once: true });
  })], { timeoutMs: 100 });
  const response = await h.worker.fetch(request(), h.env);
  assert.equal(response.status, 200);
  assert.equal(aborted, true);
  assertOriginalDraft(await response.json());
  assert.equal(h.calls.length, 2);
  assert.equal(response.headers.get("X-Dobby-AI-Search-Calls"), "0");
  assert.equal(response.headers.get("X-Dobby-AI-Search-Attempts"), "1");
  assert.equal(response.headers.get("X-Dobby-AI-Research-Status"), "incomplete");
});
