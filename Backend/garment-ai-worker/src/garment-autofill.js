import {
  buildIdentificationRequest, parseIdentificationResponse,
  buildHeritageSearchRequest, parseHeritageSearchResponse, appendHeritageToDraft,
} from "./garment-heritage.js";
import { applyCollaborationToDraft } from "./garment-collaboration.js";

function withReviewNote(draft, note) {
  return { ...draft, reviewNotes: [...new Set([note, ...draft.reviewNotes])].slice(0, 14) };
}

function mergeResearch(previous, next) {
  // Keep accepted evidence if the second search only adds brand context or fails.
  const facts = new Map();
  for (const fact of [...previous.facts, ...next.facts]) {
    if (!facts.has(fact.type)) facts.set(fact.type, fact);
  }
  const sources = new Map();
  for (const source of [...previous.sources, ...next.sources]) {
    if (!sources.has(source.url)) sources.set(source.url, source);
  }
  // Reserve one of the three research items for brand context from the start.
  const collaboration = previous.collaboration || next.collaboration || null;
  if (collaboration) sources.set(collaboration.source.url, collaboration.source);
  const desired = [...facts.values()].filter(fact => fact.type !== "brand_heritage").slice(0, 2);
  if (facts.has("brand_heritage")) desired.push(facts.get("brand_heritage"));
  // The same public source budget covers both identity verification and history.
  const selectedURLs = new Set(collaboration ? [collaboration.source.url] : []);
  if (facts.has("brand_heritage")) selectedURLs.add(facts.get("brand_heritage").sourceUrl);
  const retained = desired.filter(fact => {
    if (!selectedURLs.has(fact.sourceUrl) && selectedURLs.size >= 3) return false;
    selectedURLs.add(fact.sourceUrl);
    return true;
  });
  const usedURLs = new Set(retained.map(fact => fact.sourceUrl));
  if (collaboration) usedURLs.add(collaboration.source.url);
  return { facts: retained, sources: [...sources.values()].filter(source => usedURLs.has(source.url)),
    collaboration, matched: retained.length > 0 || collaboration !== null };
}

function applyResearch(baseline, research) {
  return applyCollaborationToDraft(appendHeritageToDraft(baseline.draft, research),
    research.collaboration, baseline.productNameWithoutBrand);
}

export async function runProductAutofill(photos, { requestResponse }) {
  const baseline = parseIdentificationResponse(await requestResponse(buildIdentificationRequest(photos)), photos);
  if (!baseline.searchable) return { draft: baseline.draft, searchCalls: 0, searchAttempts: 0, researchStatus: "skipped" };

  let previousQuery = null;
  let followUpQuery = null;
  let searchCalls = 0;
  let searchAttempts = 0;
  let collected = { facts: [], sources: [], collaboration: null, matched: false };
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const request = buildHeritageSearchRequest({
      identification: baseline.identification, attempt, previousQuery,
      garmentContext: { productName: baseline.draft.productName, description: baseline.draft.description },
      preferBrandHeritage: attempt === 2,
      collaborationCandidate: collected.collaboration ? null : baseline.collaborationCandidate,
      followUpQuery,
    });
    searchAttempts += 1;
    let payload;
    try { payload = await requestResponse(request); }
    catch (error) {
      if (error?.code === "invalid_ai_response") throw error;
      return {
        draft: withReviewNote(applyResearch(baseline, collected),
          "브랜드 자료 조사를 완료하지 못해 사진과 이미 확인한 자료의 정보만 작성했습니다."),
        searchCalls, searchAttempts, researchStatus: "incomplete",
      };
    }
    // One completed native search per attempt, at most two attempts. Invalid
    // tool activity/JSON is an error, never proof that research succeeded.
    const research = parseHeritageSearchResponse(payload, baseline.identification, baseline.collaborationCandidate);
    searchCalls += 1;
    collected = mergeResearch(collected, research);
    if (collected.facts.some(fact => fact.type === "brand_heritage")
      && (!baseline.collaborationCandidate || collected.collaboration)) {
      const draft = applyResearch(baseline, collected);
      return { draft, searchCalls, searchAttempts, researchStatus: draft.sources?.length ? "matched" : "no_match" };
    }
    previousQuery = research.query;
    // A generic brand introduction alone is not a reason to force another search.
    if (!research.nextQuery) break;
    followUpQuery = research.nextQuery;
  }
  const draft = applyResearch(baseline, collected);
  if (draft.sources?.length) return { draft, searchCalls, searchAttempts, researchStatus: "matched" };
  return {
    draft: withReviewNote(baseline.draft, "검색 자료에서 설명에 덧붙일 만한 브랜드 헤리티지나 제품 연식을 확인하지 못했습니다."),
    searchCalls, searchAttempts, researchStatus: "no_match",
  };
}
