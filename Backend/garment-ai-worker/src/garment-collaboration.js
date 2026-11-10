const CONFIDENCES = ["high", "medium", "low"];
const OFFICIAL_SOURCES = ["official_product", "official_archive", "collection_catalog"];
const nullableText = { type: ["string", "null"] };

export const COLLABORATION_CANDIDATE_SCHEMA = {
  anyOf: [{ type: "null" }, {
    type: "object", additionalProperties: false,
    properties: {
      participants: { type: "array", items: {
        type: "object", additionalProperties: false,
        properties: {
          originalName: { type: "string" }, localizedName: nullableText,
          photoId: { type: "string" }, labelText: { type: "string" },
          confidence: { type: "string", enum: CONFIDENCES },
        }, required: ["originalName", "localizedName", "photoId", "labelText", "confidence"],
      } },
      relationshipEvidence: { type: "array", items: {
        type: "object", additionalProperties: false,
        properties: {
          photoId: { type: "string" }, text: { type: "string" },
          confidence: { type: "string", enum: CONFIDENCES },
        }, required: ["photoId", "text", "confidence"],
      } },
    }, required: ["participants", "relationshipEvidence"],
  }],
};

export const COLLABORATION_RESULT_SCHEMA = {
  anyOf: [{ type: "null" }, {
    type: "object", additionalProperties: false,
    properties: {
      participantNames: { type: "array", items: { type: "string" } },
      sourceUrl: { type: "string" }, sourceKind: { type: "string", enum: OFFICIAL_SOURCES },
      subjectIdentifier: nullableText, supportingQuote: { type: "string" },
    }, required: ["participantNames", "sourceUrl", "sourceKind", "subjectIdentifier", "supportingQuote"],
  }],
};

function exactObject(value, keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function cleanText(value, maximum) {
  if (typeof value !== "string" || /[\u0000-\u001f\u007f]/u.test(value)) return null;
  const result = value.normalize("NFKC").replace(/\s+/gu, " ").trim();
  return result && result.length <= maximum ? result : null;
}

function normalized(value) {
  return value.normalize("NFKC").toLowerCase().replace(/[‐‑‒–—−]/gu, "-").replace(/\s+/gu, " ").trim();
}

function same(left, right) { return normalized(left) === normalized(right); }

function containsIdentifier(haystack, needle, { productCode = false } = {}) {
  const source = normalized(haystack);
  const target = normalized(needle);
  for (let offset = source.indexOf(target); offset >= 0; offset = source.indexOf(target, offset + 1)) {
    const before = source.slice(0, offset).at(-1) || "";
    const after = source.slice(offset + target.length, offset + target.length + 1);
    const prefix = source.slice(0, offset);
    const suffix = source.slice(offset + target.length);
    const variantContinuation = productCode && (/[\p{L}\p{N}][._/-]$/u.test(prefix)
      || /^[._/-][\p{L}\p{N}]/u.test(suffix) || /_$/u.test(prefix) || /^_/u.test(suffix));
    if (!variantContinuation && !/[\p{L}\p{N}]/u.test(before) && !/[\p{L}\p{N}]/u.test(after)) return true;
  }
  return false;
}

function namesOf(participants, localized = false) {
  return participants.map(participant => localized ? participant.localizedName || participant.originalName : participant.originalName);
}

function validParticipants(participants) {
  if (!Array.isArray(participants) || participants.length < 2 || participants.length > 5) return false;
  const seen = new Set();
  for (const participant of participants) {
    if (!exactObject(participant, ["originalName", "localizedName", "photoId", "labelText", "confidence"])
      || participant.confidence !== "high" || !cleanText(participant.originalName, 70)
      || participant.localizedName !== null && !cleanText(participant.localizedName, 70)
      || !cleanText(participant.photoId, 200) || !cleanText(participant.labelText, 400)
      || !containsIdentifier(participant.labelText, participant.originalName)) return false;
    const key = normalized(participant.originalName);
    const aliases = [key, ...(participant.localizedName ? [normalized(participant.localizedName)] : [])];
    if (aliases.some(alias => seen.has(alias))) return false;
    for (const alias of aliases) seen.add(alias);
  }
  return namesOf(participants).join(" × ").length <= 160
    && namesOf(participants, true).join(" × ").length <= 159;
}

export function sanitizeCollaborationCandidate(value, rawBrand, photos) {
  if (!exactObject(value, ["participants", "relationshipEvidence"]) || !rawBrand
    || !cleanText(rawBrand.originalName, 70) || !Array.isArray(photos)
    || !Array.isArray(value.relationshipEvidence) || value.relationshipEvidence.length > 10
    || !Array.isArray(value.participants)) return null;
  const participants = value.participants.map(participant => {
    if (!exactObject(participant, ["originalName", "localizedName", "photoId", "labelText", "confidence"])
      || participant.localizedName !== null && !cleanText(participant.localizedName, 70)) return null;
    return {
      originalName: cleanText(participant.originalName, 70),
      localizedName: participant.localizedName === null ? null : cleanText(participant.localizedName, 70),
      photoId: cleanText(participant.photoId, 200), labelText: cleanText(participant.labelText, 400),
      confidence: participant.confidence,
    };
  });
  if (participants.some(participant => !participant) || !validParticipants(participants)) return null;
  const photoIDs = new Set(photos.map(photo => photo?.id));
  if (participants.some(participant => !photoIDs.has(participant.photoId))
    || !participants.some(participant => same(participant.originalName, rawBrand.originalName))) return null;
  const relationshipEvidence = value.relationshipEvidence.flatMap(item => {
    if (!exactObject(item, ["photoId", "text", "confidence"]) || item.confidence !== "high"
      || !photoIDs.has(item.photoId)) return [];
    const evidenceText = cleanText(item.text, 600);
    return evidenceText ? [{ photoId: item.photoId, text: evidenceText, confidence: "high" }] : [];
  });
  return { participants, relationshipEvidence };
}

function publicURL(value) {
  if (typeof value !== "string" || value.length > 2048 || /[\s\\]/u.test(value)) return null;
  let url;
  try { url = new URL(value); } catch { return null; }
  const host = url.hostname.toLowerCase().replace(/\.$/u, "");
  if (url.protocol !== "https:" || url.username || url.password || url.port === "0"
    || host.length > 253 || !host.includes(".") || /^\[|^[\d.]+$/u.test(host)
    || /(?:^|\.)(?:localhost|local|localdomain|internal|lan|home|invalid|test|example|onion)$/u.test(host)
    || host.endsWith(".home.arpa") || !/^[a-z0-9.-]+$/u.test(host)
    || host.split(".").some(part => part.length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u.test(part))) return null;
  return url.href;
}

function explicitCollaboration(text, participants) {
  const value = normalized(text);
  if (/(?:\b(?:no|not|never|without|fake|unofficial)\b.{0,35}\b(?:collab(?:oration)?|partnership|co[- ]?brand)|\b(?:collab(?:oration)?|partnership)\b.{0,25}\b(?:denied|unconfirmed|rumou?r|cancelled|canceled)\b|(?:협업|콜라보|공동\s*(?:기획|제작)).{0,15}(?:아니|아님|않|없|미확인|루머|취소)|(?:미확인|루머|가짜).{0,15}(?:협업|콜라보))/iu.test(value)) return false;
  // A manufacturer's, licensee's, shop's, or parent line's name is not an
  // independent collaboration partner, even when a stray x appears nearby.
  if (/\b(?:subsidiary|sub[- ]?brand|licensee|licensor|licensed\s+(?:by|to|from)|manufactured\s+by|distributed\s+by|sold\s+by|retailed\s+by|stockist)\b|\b(?:line|label|brand)\s+of\b|\b(?:parent\s+(?:brand|company)|brand\s+line)\b|하위\s*(?:브랜드|라인)|상위\s*(?:브랜드|회사)|(?:라이선스|라이센스|제조사|판매처)\s*(?:표기|관계)/iu.test(value)) return false;
  if (/\bcollab(?:oration|orative)?\b|\bco[- ]?brand(?:ed|ing)?\b|\bjoint\s+(?:collection|project|release)\b|협업|콜라보(?:레이션)?|공동\s*(?:기획|제작|컬렉션)/iu.test(value)) return true;
  // A bare x must connect every participant. An unrelated third name after an
  // A x B mark, or measurements such as 20 x 30, cannot establish a collaboration.
  const edges = participants.map(() => new Set());
  for (let left = 0; left < participants.length; left += 1) {
    for (let right = 0; right < participants.length; right += 1) {
      if (left === right) continue;
      const first = normalized(participants[left].originalName);
      const second = normalized(participants[right].originalName);
      if ([`${first} x ${second}`, `${first} × ${second}`, `${first}×${second}`, `${first}× ${second}`, `${first} ×${second}`]
        .some(pair => containsIdentifier(value, pair))) {
        edges[left].add(right); edges[right].add(left);
      }
    }
  }
  const visited = new Set([0]);
  const pending = [0];
  while (pending.length) {
    for (const neighbor of edges[pending.pop()]) {
      if (!visited.has(neighbor)) { visited.add(neighbor); pending.push(neighbor); }
    }
  }
  return visited.size === participants.length;
}

function photographedJointLabel(candidate) {
  return Array.isArray(candidate.relationshipEvidence) && candidate.relationshipEvidence.some(item =>
    item.confidence === "high" && cleanText(item.text, 600)
    && candidate.participants.every(participant => participant.photoId === item.photoId
      && containsIdentifier(item.text, participant.originalName))
    && explicitCollaboration(item.text, candidate.participants));
}

function exactPhotographedIdentifier(value, identification, quote) {
  if (!identification || !Array.isArray(identification.evidence)) return false;
  // A known full code takes precedence over a model shared by different editions.
  const identifier = cleanText(identification.productCode, 64) || cleanText(identification.modelName, 100);
  if (!identifier || !cleanText(value, 100) || !same(value, identifier)) return false;
  const productCode = Boolean(identification.productCode);
  const kind = productCode ? "product_code" : "model_name";
  return containsIdentifier(quote, identifier, { productCode })
    && identification.evidence.some(item => item?.kind === kind && item.confidence === "high"
      && cleanText(item.photoId, 200) && cleanText(item.text, 400)
      && containsIdentifier(item.text, identifier, { productCode }));
}

export function parseCollaborationResolution(value, { candidate, identification, availableSources } = {}) {
  if (!candidate || !validParticipants(candidate.participants) || !(availableSources instanceof Map)
    || !exactObject(value, ["participantNames", "sourceUrl", "sourceKind", "subjectIdentifier", "supportingQuote"])
    || !OFFICIAL_SOURCES.includes(value.sourceKind) || !Array.isArray(value.participantNames)
    || value.participantNames.length !== candidate.participants.length) return null;
  const participantNames = value.participantNames.map(name => cleanText(name, 70));
  if (participantNames.some(name => !name) || new Set(participantNames.map(normalized)).size !== participantNames.length
    || !candidate.participants.every(participant => participantNames.some(name => same(name, participant.originalName)))) return null;
  const sourceUrl = publicURL(value.sourceUrl);
  const source = sourceUrl && availableSources.get(sourceUrl);
  const quote = cleanText(value.supportingQuote, 1000);
  const hasPhotoIdentifier = Boolean(cleanText(identification?.productCode, 64) || cleanText(identification?.modelName, 100));
  // A photographed joint label cannot excuse a conflicting (or omitted) code
  // on a known product. It only binds a source when neither side names a model.
  const garmentBound = hasPhotoIdentifier || value.subjectIdentifier !== null
    ? exactPhotographedIdentifier(value.subjectIdentifier, identification, quote || "")
    : photographedJointLabel(candidate);
  if (!source || publicURL(source.url) !== sourceUrl || !quote
    || !candidate.participants.every(participant => containsIdentifier(quote, participant.originalName))
    || !explicitCollaboration(quote, candidate.participants)
    || !garmentBound) return null;
  return { participants: candidate.participants.map(participant => ({ ...participant })),
    source: { title: cleanText(source.title, 300) || new URL(sourceUrl).hostname, url: sourceUrl } };
}

function removeLeadingBrands(name, participants) {
  const prefixes = [...new Set([
    namesOf(participants).join(" × "), namesOf(participants, true).join(" × "),
    namesOf(participants).join(" x "), namesOf(participants, true).join(" x "),
    ...participants.flatMap(participant => [participant.originalName, participant.localizedName].filter(Boolean)),
  ])].sort((left, right) => right.length - left.length);
  let result = name;
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const prefix = prefixes.find(item => normalized(result).startsWith(normalized(item))
      && (result.length === item.length || /^[\s·:—–-]/u.test(result.slice(item.length))));
    if (!prefix) break;
    result = result.slice(prefix.length).replace(/^[\s·:—–-]+/u, "");
  }
  return result;
}

export function applyCollaborationToDraft(draft, resolution, productNameWithoutBrand) {
  if (!draft || !resolution || !validParticipants(resolution.participants)) return draft;
  const suppliedName = cleanText(productNameWithoutBrand, 300);
  const sourceUrl = publicURL(resolution.source?.url);
  if (!suppliedName || !sourceUrl) return draft;
  const name = removeLeadingBrands(suppliedName, resolution.participants);
  const brand = namesOf(resolution.participants).join(" × ");
  const prefix = namesOf(resolution.participants, true).join(" × ");
  const productName = `${prefix} ${name}`;
  if (!name || brand.length > 160 || productName.length > 300) return draft;
  const sources = new Map([[sourceUrl, { title: cleanText(resolution.source.title, 300) || new URL(sourceUrl).hostname, url: sourceUrl }]]);
  for (const source of Array.isArray(draft.sources) ? draft.sources : []) {
    const url = publicURL(source?.url);
    if (url && !sources.has(url)) sources.set(url, { title: cleanText(source.title, 300) || new URL(url).hostname, url });
  }
  return { ...draft, brand, productName, sources: [...sources.values()].slice(0, 3) };
}
