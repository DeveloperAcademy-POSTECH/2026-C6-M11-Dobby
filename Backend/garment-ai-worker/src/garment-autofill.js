import { readCroppedBrandLabels } from "./brand-label-pilot.js";
import { buildBrandDiscoveryRequest, parseBrandDiscoveryResponse, applyDiscoveredBrand, buildBrandReadbackRequest, parseBrandReadbackResponse } from "./garment-brand-discovery.js";
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
  const identitySource = previous.identitySource || next.identitySource || null;
  if (identitySource) sources.set(identitySource.url, identitySource);
  // Reserve one of the three research items for brand context from the start.
  const collaboration = previous.collaboration || next.collaboration || null;
  if (collaboration) sources.set(collaboration.source.url, collaboration.source);
  const desired = [...facts.values()].filter(fact => fact.type !== "brand_heritage").slice(0, 2);
  if (facts.has("brand_heritage")) desired.push(facts.get("brand_heritage"));
  // The same public source budget covers both identity verification and history.
  const selectedURLs = new Set(collaboration ? [collaboration.source.url] : []);
  if (identitySource) selectedURLs.add(identitySource.url);
  if (facts.has("brand_heritage")) selectedURLs.add(facts.get("brand_heritage").sourceUrl);
  const retained = desired.filter(fact => {
    if (!selectedURLs.has(fact.sourceUrl) && selectedURLs.size >= 3) return false;
    selectedURLs.add(fact.sourceUrl);
    return true;
  });
  const usedURLs = new Set(retained.map(fact => fact.sourceUrl));
  if (collaboration) usedURLs.add(collaboration.source.url);
  if (identitySource) usedURLs.add(identitySource.url);
  return { facts: retained, sources: [...sources.values()].filter(source => usedURLs.has(source.url)),
    collaboration, identitySource, matched: retained.length > 0 || collaboration !== null || identitySource !== null };
}

function applyResearch(baseline, research) {
  const draft = applyCollaborationToDraft(appendHeritageToDraft(baseline.draft, research),
    research.collaboration, baseline.productNameWithoutBrand);
  if (!research.identitySource) return draft;
  const sources = new Map([[research.identitySource.url, research.identitySource]]);
  for (const source of draft.sources || []) sources.set(source.url, source);
  return { ...draft, sources: [...sources.values()].slice(0, 3) };
}

export async function runProductAutofill(photos, { requestResponse, verifyKnownBrand = false, labelCrops, onBrandDecision }) {
  // Photo features and independent label reading do not depend on each other.
  // Await both settlements so a failed baseline cannot leave a request running.
  const initialRequest = requestResponse(buildIdentificationRequest(photos));
  const labelRequest = labelCrops?.length ? readCroppedBrandLabels(labelCrops, { requestResponse }) : Promise.resolve(null);
  const [initial, label] = await Promise.allSettled([initialRequest, labelRequest]);
  if (initial.status === "rejected") throw initial.reason;
  let baseline = parseIdentificationResponse(initial.value, photos);

  if (labelCrops !== undefined) {
    const labelResult = label.status === "fulfilled" ? label.value : null;
    const observation = labelResult?.brand || null;
    onBrandDecision?.({ status: observation ? "verified" : "unverified",
      reason: observation ? "verified" : label.status === "rejected" ? "label_read_failed"
        : labelResult?.brandRejection || "no_ocr_crop" });
    if (observation) {
      const crop = labelCrops.find(photo => photo.id === observation.photoId);
      const identity = { brand: observation.originalName, productCode: null, modelName: null, manufactureYear: null,
        evidence: [{ kind: "brand_label", text: observation.observedText, photoId: crop.sourcePhotoId, confidence: "high" }] };
      const sameBrand = baseline.identification?.brand.normalize("NFKC").toLowerCase()
        === observation.originalName.normalize("NFKC").toLowerCase();
      baseline = { ...applyDiscoveredBrand(baseline, { brand: observation, identity: sameBrand ? baseline.identification : identity }),
        collaborationCandidate: sameBrand ? baseline.collaborationCandidate : null };
    } else {
      baseline = { ...baseline, searchable: false, identification: null, collaborationCandidate: null,
        draft: withReviewNote({ ...baseline.draft, brand: null, productName: baseline.productNameWithoutBrand },
          "라벨 크롭·회전 OCR에서 브랜드를 확정하지 못했습니다. 실물 라벨을 확인해 주세요.") };
    }
  }

  // A confident first-pass guess still needs an independent label reading.
  // Never expose that guess (or a search result) to the readback request.
  if (verifyKnownBrand && baseline.searchable) {
    try {
      const readback = parseBrandReadbackResponse(await requestResponse(buildBrandReadbackRequest(photos)), photos);
      if (readback) {
        const sameBrand = readback.brand.originalName.normalize("NFKC").toLowerCase()
          === baseline.identification.brand.normalize("NFKC").toLowerCase();
        if (!sameBrand) {
          // Product codes and collaboration candidates from the rejected brand
          // must not contaminate the new brand's search or generated title.
          baseline = { ...applyDiscoveredBrand(baseline, readback), collaborationCandidate: null };
        }
      } else {
        baseline.draft = withReviewNote(baseline.draft, "브랜드를 독립 라벨 판독에서 재확인하지 못했습니다. 실물 라벨과 대조해 주세요.");
      }
    } catch {
      // Optional verification must not turn a usable photo draft into an error.
      baseline.draft = withReviewNote(baseline.draft, "브랜드 독립 라벨 판독을 완료하지 못했습니다. 실물 라벨과 대조해 주세요.");
    }
  }

  let previousQuery = null;
  let followUpQuery = null;
  let searchCalls = 0;
  let searchAttempts = 0;
  let collected = { facts: [], sources: [], collaboration: null, matched: false };
  // Valid garment photos always enter native web search, even without a brand.
  // Discovery consumes the same two-search budget as ordinary heritage research.
  if (!baseline.searchable) {
    searchAttempts = 1;
    let payload;
    try { payload = await requestResponse(buildBrandDiscoveryRequest(photos, baseline.draft)); }
    catch (error) {
      if (error?.code === "invalid_ai_response") throw error;
      return { draft: withReviewNote(baseline.draft, "브랜드 확인을 위한 검색을 완료하지 못했습니다. 실물 라벨을 확인해 주세요."),
        searchCalls, searchAttempts, researchStatus: "incomplete" };
    }
    const discovery = parseBrandDiscoveryResponse(payload, photos);
    searchCalls = 1;
    if (labelCrops !== undefined) {
      return { draft: withReviewNote(baseline.draft, "사진 단서로 검색했지만 OCR과 대조된 브랜드 근거가 없어 브랜드를 비워 두었습니다."),
        searchCalls, searchAttempts, researchStatus: "no_match" };
    }
    if (!discovery.identity) {
      return { draft: withReviewNote(baseline.draft, "사진 단서로 검색했지만 브랜드를 확정할 근거를 확인하지 못했습니다."),
        searchCalls, searchAttempts, researchStatus: "no_match" };
    }
    // Search candidates cannot authenticate their own reading of a logo. Read
    // the original labels independently, without exposing the search candidate.
    let readback;
    try { readback = parseBrandReadbackResponse(await requestResponse(buildBrandReadbackRequest(photos)), photos); }
    catch {
      return { draft: withReviewNote(baseline.draft, "검색 후 사진 라벨 재확인을 완료하지 못해 브랜드를 보완하지 않았습니다."),
        searchCalls, searchAttempts, researchStatus: "incomplete" };
    }
    if (!readback) {
      return { draft: withReviewNote(baseline.draft, "검색 후보를 실제 사진 라벨에서 재확인하지 못해 브랜드를 보완하지 않았습니다."),
        searchCalls, searchAttempts, researchStatus: "no_match" };
    }
    const sameBrand = readback.brand.originalName.normalize("NFKC").toLowerCase()
      === discovery.brand.originalName.normalize("NFKC").toLowerCase();
    baseline = applyDiscoveredBrand(baseline, sameBrand ? { ...readback, source: discovery.source } : readback);
    if (sameBrand) {
      collected = mergeResearch(collected, { ...discovery.research, identitySource: discovery.source });
      if (collected.facts.some(fact => fact.type === "brand_heritage")) {
        return { draft: applyResearch(baseline, collected), searchCalls, searchAttempts, researchStatus: "matched" };
      }
      previousQuery = discovery.research.query;
      followUpQuery = discovery.research.nextQuery || null;
    }
    // If the independent label differs, discard all candidate research and use
    // the remaining search for the actually photographed label instead.
  }
  for (let attempt = searchAttempts + 1; attempt <= 2; attempt += 1) {
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
