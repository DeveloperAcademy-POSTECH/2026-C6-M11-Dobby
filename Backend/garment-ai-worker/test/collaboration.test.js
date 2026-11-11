import test from "node:test";
import assert from "node:assert/strict";
import {
  COLLABORATION_CANDIDATE_SCHEMA, COLLABORATION_RESULT_SCHEMA,
  sanitizeCollaborationCandidate, parseCollaborationResolution, applyCollaborationToDraft,
} from "../src/garment-collaboration.js";

// Every product, photo, brand combination, quote, and URL is an injected fixture.
// No test makes a network request or asserts that a commercial product exists.
const PHOTOS = [{ id: "front" }, { id: "joint-label" }, { id: "other-label" }];
const BRAND = { originalName: "ALPHA", localizedName: "알파" };
const SOURCE = { title: "Synthetic official collection", url: "https://catalog.fixture-fashion.com/collaboration" };
const SOURCES = new Map([[SOURCE.url, SOURCE]]);
const DRAFT = {
  brand: "ALPHA (알파)", productName: "알파 블랙 그래픽 재킷",
  description: "- 블랙 바탕의 그래픽 포인트", reviewNotes: [],
};

function participant(originalName, localizedName, photoId = "joint-label") {
  return { originalName, localizedName, photoId, labelText: originalName, confidence: "high" };
}

function candidate({ joint = true, triple = false } = {}) {
  const participants = [participant("ALPHA", "알파"), participant("BETA", "베타")];
  if (triple) participants.push(participant("GAMMA", null));
  return {
    participants,
    relationshipEvidence: joint ? [{ photoId: "joint-label", confidence: "high",
      text: participants.map(item => item.originalName).join(" x ") }] : [],
  };
}

function identification(overrides = {}) {
  return { brand: "ALPHA", productCode: "AB123-010", modelName: null, evidence: [
    { kind: "product_code", text: "AB123-010", confidence: "high", photoId: "other-label" },
  ], ...overrides };
}

function result(overrides = {}) {
  return {
    participantNames: ["ALPHA", "BETA"], sourceUrl: SOURCE.url, sourceKind: "official_product",
    subjectIdentifier: null, supportingQuote: "ALPHA and BETA created this collaboration collection.", ...overrides,
  };
}

function resolve(value = result(), options = {}) {
  return parseCollaborationResolution(value, { candidate: candidate(), identification: null, availableSources: SOURCES, ...options });
}

test("internal schemas are nullable and require bounded parsing data without changing public fields", () => {
  assert.equal(COLLABORATION_CANDIDATE_SCHEMA.anyOf[0].type, "null");
  assert.equal(COLLABORATION_RESULT_SCHEMA.anyOf[0].type, "null");
  assert.deepEqual(COLLABORATION_CANDIDATE_SCHEMA.anyOf[1].required, ["participants", "relationshipEvidence"]);
  assert.equal(COLLABORATION_RESULT_SCHEMA.anyOf[1].additionalProperties, false);
});

test("a candidate retains photographed names and can wait for search without joint-label proof", () => {
  assert.deepEqual(sanitizeCollaborationCandidate(candidate({ joint: false }), BRAND, PHOTOS), candidate({ joint: false }));
  const input = candidate();
  input.participants[0].labelText = "  ALPHA  ";
  const sanitized = sanitizeCollaborationCandidate(input, BRAND, PHOTOS);
  assert.equal(sanitized.participants[0].labelText, "ALPHA");
  assert.notEqual(sanitized.participants, input.participants);
});

test("candidate names need high-confidence text, selected photos, a known primary, and uniqueness", async t => {
  const cases = [
    ["missing candidate", null],
    ["one participant", { ...candidate(), participants: candidate().participants.slice(0, 1) }],
    ["six participants", { ...candidate(), participants: Array.from({ length: 6 }, (_, i) => participant(`BRAND${i}`, null)) }],
    ["case duplicate", { ...candidate(), participants: [participant("ALPHA", null), participant("alpha", null)] }],
    ["localized alias duplicate", { ...candidate(), participants: [participant("ALPHA", "알파"), participant("알파", null)] }],
    ["unknown primary", { ...candidate(), participants: [participant("BETA", null), participant("GAMMA", null)] }],
  ];
  for (const confidence of ["medium", "low", "invented"]) {
    const value = candidate(); value.participants[1].confidence = confidence;
    cases.push([`confidence ${confidence}`, value]);
  }
  for (const [key, content] of [["labelText", "unreadable logo"], ["labelText", "BETAMAX"], ["photoId", "not-selected"],
    ["originalName", ""], ["localizedName", 12], ["extra", "unsupported"]]) {
    const value = candidate(); value.participants[1][key] = content;
    cases.push([`invalid participant ${key} ${content}`, value]);
  }
  for (const [name, value] of cases) await t.test(name, () => assert.equal(sanitizeCollaborationCandidate(value, BRAND, PHOTOS), null));
  assert.equal(sanitizeCollaborationCandidate(candidate(), null, PHOTOS), null);
});

test("candidate lengths are bounded without truncating or silently dropping any brand", () => {
  const first = "A".repeat(70);
  const second = "B".repeat(70);
  const third = "C".repeat(70);
  const value = { participants: [participant(first, null), participant(second, null), participant(third, null)], relationshipEvidence: [] };
  assert.equal(sanitizeCollaborationCandidate(value, { originalName: first }, PHOTOS), null);
  const localized = candidate(); localized.participants[0].localizedName = "가".repeat(70);
  localized.participants[1].localizedName = "나".repeat(70);
  localized.participants.push(participant("GAMMA", "다".repeat(70)));
  assert.equal(sanitizeCollaborationCandidate(localized, BRAND, PHOTOS), null);
});

test("uncertain relationship evidence is dropped while valid photographed candidates survive", () => {
  const input = candidate();
  input.relationshipEvidence = [
    { photoId: "joint-label", text: "ALPHA x BETA", confidence: "medium" },
    { photoId: "not-selected", text: "ALPHA x BETA", confidence: "high" },
    { photoId: "joint-label", text: "ALPHA x BETA", confidence: "high", extra: "ignored" },
  ];
  assert.deepEqual(sanitizeCollaborationCandidate(input, BRAND, PHOTOS).relationshipEvidence, []);
});

test("an official native source plus a photographed joint label confirms a collaboration", () => {
  const resolution = resolve();
  assert.deepEqual(resolution.participants, candidate().participants);
  assert.deepEqual(resolution.source, SOURCE);
  assert.deepEqual(Object.keys(resolution).sort(), ["participants", "source"]);
  assert.equal(resolve(result({ participantNames: ["BETA", "ALPHA"] })).participants[0].originalName, "ALPHA");
});

test("separate logos can be resolved only through a matching photographed full product identifier", () => {
  const separate = candidate({ joint: false });
  separate.participants[1].photoId = "other-label";
  const value = result({ subjectIdentifier: "AB123-010", supportingQuote: "ALPHA x BETA collaboration jacket AB123-010." });
  assert.ok(resolve(value, { candidate: separate, identification: identification() }));
  assert.equal(resolve(result(), { candidate: separate }), null);
  assert.equal(resolve(value, { candidate: separate, identification: identification({ evidence: [] }) }), null);
  assert.equal(resolve(value, { candidate: separate, identification: identification({ evidence: [
    { kind: "product_code", text: "AB123-010", confidence: "low", photoId: "other-label" },
  ] }) }), null);
});

test("a photographed model may bind a product only when no more specific code is known", () => {
  const id = identification({ productCode: null, modelName: "Fixture Denim Jacket", evidence: [
    { kind: "model_name", text: "Fixture Denim Jacket", confidence: "high", photoId: "other-label" },
  ] });
  const value = result({ subjectIdentifier: "Fixture Denim Jacket", supportingQuote: "ALPHA x BETA collaboration: Fixture Denim Jacket." });
  assert.ok(resolve(value, { candidate: candidate({ joint: false }), identification: id }));
  assert.equal(resolve(value, { candidate: candidate({ joint: false }), identification: { ...id, productCode: "AB123-010" } }), null);
});

test("a joint label never bypasses a known product identifier or an unsupported source identifier", async t => {
  const id = identification();
  const cases = [
    ["different returned identifier", result({ subjectIdentifier: "AB123-011", supportingQuote: "ALPHA x BETA collaboration AB123-011." }), id],
    ["omitted returned identifier", result(), id],
    ["right identifier absent from quote", result({ subjectIdentifier: "AB123-010", supportingQuote: "ALPHA x BETA collaboration AB123-011." }), id],
    ["unphotographed source identifier", result({ subjectIdentifier: "AB123-010", supportingQuote: "ALPHA x BETA collaboration AB123-010." }), null],
    ["missing high-confidence photo proof", result({ subjectIdentifier: "AB123-010", supportingQuote: "ALPHA x BETA collaboration AB123-010." }), identification({ evidence: [] })],
  ];
  for (const [name, value, photoIdentity] of cases) await t.test(name, () => {
    assert.equal(resolve(value, { identification: photoIdentity }), null);
  });
  assert.ok(resolve(result({ subjectIdentifier: "AB123-010", supportingQuote: "ALPHA x BETA collaboration AB123-010." }), { identification: id }));
  assert.ok(resolve(result(), { identification: null }));
});

test("similar product codes, different variants, unconfirmed models, and generic collaboration articles cannot bind this garment", async t => {
  const separate = candidate({ joint: false });
  for (const quote of [
    "ALPHA x BETA collaboration jacket AB123-0100.",
    "ALPHA x BETA collaboration jacket AB123-010-RED.",
    "ALPHA x BETA collaboration jacket OTHER-AB123-010.",
    "ALPHA x BETA have collaborated in the past.",
  ]) await t.test(quote, () => assert.equal(resolve(result({ subjectIdentifier: "AB123-010", supportingQuote: quote }), { candidate: separate, identification: identification() }), null));
  assert.equal(resolve(result({ subjectIdentifier: "AB123-011", supportingQuote: "ALPHA x BETA collaboration AB123-011." }), { candidate: separate, identification: identification() }), null);
});

test("the source must be an official product/archive/catalogue URL actually returned by the current search", async t => {
  for (const sourceKind of ["retailer_product", "resale_listing", "official_about", "official_history", "unknown"]) {
    await t.test(sourceKind, () => assert.equal(resolve(result({ sourceKind })), null));
  }
  for (const sourceUrl of ["https://catalog.fixture-fashion.com/not-returned", "http://catalog.fixture-fashion.com/collaboration",
    "https://127.0.0.1/collaboration", "https://internal.local/collaboration", "https://user:password@catalog.fixture-fashion.com/collaboration"]) {
    await t.test(sourceUrl, () => assert.equal(resolve(result({ sourceUrl })), null));
  }
  assert.equal(resolve(result(), { availableSources: new Map() }), null);
  assert.equal(resolve(result({ sourceKind: "collection_catalog" })).source.url, SOURCE.url);
});

test("all photographed participants must be named in the response and direct collaboration quote", async t => {
  const cases = [
    result({ participantNames: ["ALPHA", "GAMMA"] }),
    result({ participantNames: ["ALPHA"] }),
    result({ participantNames: ["ALPHA", "BETA", "GAMMA"] }),
    result({ participantNames: ["ALPHA", "alpha"] }),
    result({ supportingQuote: "ALPHA collaboration jacket." }),
    result({ supportingQuote: "ALPHABET x BETA collaboration collection." }),
    result({ supportingQuote: "ALPHA and BETA garments with measurements 20 x 30." }),
    result({ supportingQuote: "ALPHA and BETA are both sold at our store." }),
    result({ supportingQuote: "ALPHA is manufactured by BETA." }),
    result({ supportingQuote: "ALPHA is licensed by BETA." }),
  ];
  for (const [i, value] of cases.entries()) await t.test(`rejected evidence ${i}`, () => assert.equal(resolve(value), null));
});

test("a rejected, denied, or unconfirmed collaboration cannot be promoted by a search result", async t => {
  for (const supportingQuote of [
    "ALPHA x BETA is not a collaboration.",
    "ALPHA and BETA have no official collaboration.",
    "ALPHA and BETA collaboration is unconfirmed.",
    "ALPHA x BETA collaboration was cancelled.",
    "ALPHA와 BETA의 협업은 아닙니다.",
    "ALPHA와 BETA의 콜라보는 미확인 루머입니다.",
  ]) await t.test(supportingQuote, () => assert.equal(resolve(result({ supportingQuote })), null));
});

test("RRL and its Ralph Lauren parent are a line relationship, not two collaboration partners", () => {
  const lines = { participants: [participant("RRL", null), participant("Ralph Lauren", null)], relationshipEvidence: [] };
  const sanitized = sanitizeCollaborationCandidate(lines, { originalName: "RRL", localizedName: null }, PHOTOS);
  assert.ok(sanitized);
  const value = result({ participantNames: ["RRL", "Ralph Lauren"], supportingQuote: "RRL is a Ralph Lauren line inspired by workwear." });
  assert.equal(resolve(value, { candidate: sanitized, identification: { brand: "RRL", productCode: null, modelName: null, evidence: [] } }), null);
  assert.equal(resolve({ ...value, supportingQuote: "RRL x Ralph Lauren denotes a line of Ralph Lauren." }, { candidate: sanitized }), null);
});

test("a joint mark must include all names together on the same selected label photograph", () => {
  const input = candidate(); input.participants[1].photoId = "other-label";
  assert.equal(resolve(result(), { candidate: input }), null);
  const scattered = candidate(); scattered.relationshipEvidence[0].text = "ALPHA BETA";
  assert.equal(resolve(result(), { candidate: scattered }), null);
  const low = candidate(); low.relationshipEvidence[0].confidence = "low";
  assert.equal(resolve(result(), { candidate: low }), null);
});

test("a triple collaboration preserves photograph order and all three brands in public brand and title", () => {
  const input = candidate({ triple: true });
  const resolution = resolve(result({ participantNames: ["GAMMA", "BETA", "ALPHA"],
    supportingQuote: "ALPHA x BETA x GAMMA collaboration collection." }), { candidate: input });
  assert.ok(resolution);
  const applied = applyCollaborationToDraft(DRAFT, resolution, "블랙 그래픽 재킷");
  assert.equal(applied.brand, "ALPHA × BETA × GAMMA");
  assert.equal(applied.productName, "알파 × 베타 × GAMMA 블랙 그래픽 재킷");
  assert.equal(applied.description, DRAFT.description);
  assert.deepEqual(applied.reviewNotes, DRAFT.reviewNotes);
  assert.deepEqual(applied.sources, [SOURCE]);
  assert.deepEqual(Object.keys(applied).sort(), ["brand", "description", "productName", "reviewNotes", "sources"]);
});

test("a bare x mark must connect all participants rather than an unrelated third name", () => {
  const input = candidate({ triple: true });
  const value = result({ participantNames: ["ALPHA", "BETA", "GAMMA"], supportingQuote: "ALPHA x BETA. GAMMA appears elsewhere." });
  assert.equal(resolve(value, { candidate: input }), null);
  assert.ok(resolve({ ...value, supportingQuote: "ALPHA × BETA × GAMMA." }, { candidate: input }));
  assert.ok(resolve({ ...value, supportingQuote: "ALPHA× BETA ×GAMMA." }, { candidate: input }));
  input.relationshipEvidence[0].text = "ALPHA x BETA. GAMMA appears elsewhere.";
  assert.equal(resolve({ ...value, supportingQuote: "ALPHA × BETA × GAMMA." }, { candidate: input }), null);
});

test("title composition removes only complete leading participant or collaboration tokens", () => {
  const resolution = resolve();
  for (const input of ["ALPHA 블랙 재킷", "알파 블랙 재킷", "ALPHA × BETA 블랙 재킷", "알파 × 베타 블랙 재킷", "ALPHA x BETA 블랙 재킷", "ALPHA ALPHA BETA 블랙 재킷"]) {
    assert.equal(applyCollaborationToDraft(DRAFT, resolution, input).productName, "알파 × 베타 블랙 재킷");
  }
  assert.equal(applyCollaborationToDraft(DRAFT, resolution, "ALPHABET 그래픽 재킷").productName, "알파 × 베타 ALPHABET 그래픽 재킷");
  assert.equal(applyCollaborationToDraft(DRAFT, resolution, "빅 ALPHA 그래픽 재킷").productName, "알파 × 베타 빅 ALPHA 그래픽 재킷");
  assert.equal(applyCollaborationToDraft(DRAFT, resolution, "ALPHA × BETA"), DRAFT);
});

test("the collaboration source survives a full existing source list without exposing supporting quotes", () => {
  const existing = Array.from({ length: 3 }, (_, i) => ({ title: `Previous ${i}`, url: `https://catalog.fixture-fashion.com/history/${i}` }));
  const applied = applyCollaborationToDraft({ ...DRAFT, sources: existing }, resolve(), "블랙 재킷");
  assert.equal(applied.sources.length, 3);
  assert.deepEqual(applied.sources[0], SOURCE);
  assert.equal(JSON.stringify(applied).includes("supportingQuote"), false);
  const repeated = applyCollaborationToDraft(applied, resolve(), "블랙 재킷");
  assert.deepEqual(repeated.sources, applied.sources);
});

test("invalid composition and overlong names preserve the previous draft unchanged", () => {
  const resolution = resolve();
  for (const name of [null, "", "ALPHA", "a".repeat(300), "a".repeat(301), "bad\u0000name"]) {
    assert.equal(applyCollaborationToDraft(DRAFT, resolution, name), DRAFT);
  }
  assert.equal(applyCollaborationToDraft(DRAFT, null, "블랙 재킷"), DRAFT);
  assert.equal(applyCollaborationToDraft(DRAFT, { ...resolution, source: { url: "https://127.0.0.1/private" } }, "블랙 재킷"), DRAFT);
});
