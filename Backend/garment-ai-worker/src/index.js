import { buildOpenAIRequest, DraftResponseError, parseOpenAIResponse } from "./garment-draft.js";
import { locateBrandLabels, readCroppedBrandLabels } from "./brand-label-pilot.js";
import { runProductAutofill } from "./garment-autofill.js";
import { buildLandmarkOpenAIRequest, buildRefinementOpenAIRequest, OUTERWEAR_CATEGORIES,
  buildNeckRefinementOpenAIRequest, parseNeckRefinementOpenAIResponse, NECK_REFINEMENT_REGIONS,
  buildLengthRefinementOpenAIRequest, parseLengthRefinementOpenAIResponse, LENGTH_REFINEMENT_REGIONS,
  parseLandmarkOpenAIResponse, REFINEMENT_REGIONS, REFINEMENT_VERSION, REFINEMENT_VERSION_V3, REFINEMENT_VERSION_V4 } from "./garment-landmarks.js";
import { enforceAppUsageLimits, UsageProtectionFailure } from "./usage-protection.js";

const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
const MAX_PHOTOS = 5;
const MAX_PHOTO_BYTES = 2 * 1024 * 1024;
const MAX_TOTAL_PHOTO_BYTES = 8 * 1024 * 1024;
const MAX_BODY_BYTES = 12 * 1024 * 1024;
const PHOTO_ROLES = new Set(["front", "back", "label", "detail", "defect"]);
const BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const DATA_URL_MIME_TYPES = new Map([
  ["data:image/jpeg;base64", "image/jpeg"],
  ["data:image/png;base64", "image/png"],
  ["data:image/webp;base64", "image/webp"],
]);

class Failure extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function json(body, status, requestId, extraHeaders = {}) {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Request-Id": requestId,
      ...extraHeaders,
    },
  });
}

function autofillHeaders(result) {
  const headers = {
    "X-Dobby-AI-Search-Calls": String(result.searchCalls),
    "X-Dobby-AI-Search-Attempts": String(result.searchAttempts),
    "X-Dobby-AI-Research-Status": result.researchStatus,
  };
  for (const [stage, name] of Object.entries({ identification: "Identification", label: "Label-Read", search: "Search", server: "Server" })) {
    const value = result.stageTimings?.[stage];
    if (Number.isFinite(value) && value >= 0) headers[`X-Dobby-AI-${name}-Ms`] = String(Math.round(value));
  }
  if (result.brandDecision) {
    headers["X-Dobby-AI-Brand-Status"] = result.brandDecision.status;
    headers["X-Dobby-AI-Brand-Reason"] = result.brandDecision.reason;
  }
  return headers;
}

function failureResponse(error, requestId) {
  const failure = error instanceof Failure || error instanceof UsageProtectionFailure
    ? error
    : new Failure(500, "internal_error", "서버 처리 중 오류가 발생했습니다.");
  return json({ error: { code: failure.code, message: failure.message }, requestId },
    failure.status, requestId, failure.headers);
}

function hasSecret(value) {
  return typeof value === "string" && value.length > 0 && !/\s/.test(value);
}

async function equalSecrets(actual, expected) {
  // Compare fixed-length hashes so token length does not affect the comparison loop.
  const encoder = new TextEncoder();
  const [actualHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(actual)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const left = new Uint8Array(actualHash);
  const right = new Uint8Array(expectedHash);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

async function authorize(request, env) {
  const bearer = request.headers.get("Authorization") || "";
  const match = /^Bearer ([^\s]+)$/i.exec(bearer);
  // An app header explicitly selects app authentication. Invalid app credentials
  // never fall back to the trusted legacy development token.
  if (request.headers.has("X-Dobby-App-Key")) {
    if (!hasSecret(env?.DOBBY_APP_API_KEY) || !hasSecret(env?.OPENAI_API_KEY)) {
      throw new Failure(503, "service_not_configured", "AI 연결 서버 설정이 필요합니다.");
    }
    const appKey = request.headers.get("X-Dobby-App-Key");
    if (!hasSecret(appKey) || appKey.length > 1024 || !match || !/^[a-f0-9]{64}$/.test(match[1])
      || !await equalSecrets(appKey, env.DOBBY_APP_API_KEY)) {
      throw new Failure(401, "unauthorized", "요청 인증 정보를 확인해 주세요.");
    }
    return { kind: "app", installationID: match[1] };
  }
  if (!hasSecret(env?.DRAFT_API_TOKEN) || !hasSecret(env?.OPENAI_API_KEY)) {
    throw new Failure(503, "service_not_configured", "AI 연결 서버 설정이 필요합니다.");
  }
  if (!match || match[1].length > 1024 || !await equalSecrets(match[1], env.DRAFT_API_TOKEN)) {
    throw new Failure(401, "unauthorized", "요청 인증 정보를 확인해 주세요.");
  }
  return { kind: "legacy" };
}

async function readJSON(request) {
  const contentType = (request.headers.get("Content-Type") || "").split(";", 1)[0].trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new Failure(415, "unsupported_content_type", "JSON 형식으로 사진을 전송해 주세요.");
  }
  const lengthHeader = request.headers.get("Content-Length");
  if (lengthHeader !== null && (!/^\d+$/.test(lengthHeader) || Number(lengthHeader) > MAX_BODY_BYTES)) {
    throw new Failure(413, "request_too_large", "요청 용량은 12MiB 이하여야 합니다.");
  }
  const reader = request.body?.getReader();
  if (!reader) throw new Failure(400, "invalid_request", "사진 요청 내용이 필요합니다.");
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY_BYTES) {
        try { await reader.cancel(); } catch { /* The size limit still takes precedence. */ }
        throw new Failure(413, "request_too_large", "요청 용량은 12MiB 이하여야 합니다.");
      }
      chunks.push(value);
    }
  } catch (error) {
    if (error instanceof Failure) throw error;
    throw new Failure(400, "invalid_request", "사진 요청을 읽지 못했습니다.");
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Failure(400, "invalid_json", "요청 JSON 형식이 올바르지 않습니다.");
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(value, allowed) {
  return Object.keys(value).every(key => allowed.includes(key));
}

function hasImageSignature(prefix, mimeType) {
  const byte = index => prefix.charCodeAt(index);
  if (mimeType === "image/jpeg") {
    return prefix.length >= 3 && byte(0) === 0xff && byte(1) === 0xd8 && byte(2) === 0xff;
  }
  if (mimeType === "image/png") {
    return prefix.startsWith("\x89PNG\r\n\x1a\n");
  }
  return prefix.length >= 12 && prefix.slice(0, 4) === "RIFF" && prefix.slice(8, 12) === "WEBP";
}

function imageBytes(dataURL) {
  if (typeof dataURL !== "string") {
    throw new Failure(400, "invalid_photo", "사진은 JPEG, PNG, WebP 데이터 URL이어야 합니다.");
  }
  const comma = dataURL.indexOf(",");
  const mimeType = DATA_URL_MIME_TYPES.get(dataURL.slice(0, comma));
  if (comma < 0 || !mimeType) {
    throw new Failure(400, "invalid_photo", "사진은 JPEG, PNG, WebP 데이터 URL이어야 합니다.");
  }
  const encoded = dataURL.slice(comma + 1);
  const padding = encoded.endsWith("==") ? 2 : encoded.endsWith("=") ? 1 : 0;
  const size = encoded.length / 4 * 3 - padding;
  if (size > MAX_PHOTO_BYTES) {
    throw new Failure(413, "photo_too_large", "사진 한 장의 용량은 2MiB 이하여야 합니다.");
  }
  const firstPadding = encoded.indexOf("=");
  const lastValue = BASE64_ALPHABET.indexOf(encoded[encoded.length - padding - 1]);
  if (!encoded.length || encoded.length % 4 !== 0 || /[^A-Za-z0-9+/=]/.test(encoded)
      || (firstPadding !== -1 && firstPadding !== encoded.length - padding)
      || (padding === 2 && lastValue % 16 !== 0)
      || (padding === 1 && lastValue % 4 !== 0)) {
    throw new Failure(400, "invalid_photo", "사진의 Base64 형식이 올바르지 않습니다.");
  }
  // Decode only a short prefix; the API receives the original data URL.
  let prefix;
  try { prefix = atob(encoded.slice(0, 24)); }
  catch { throw new Failure(400, "invalid_photo", "사진의 Base64 형식이 올바르지 않습니다."); }
  if (!hasImageSignature(prefix, mimeType)) {
    throw new Failure(400, "invalid_photo", "사진 형식과 파일 내용이 일치하지 않습니다.");
  }
  return size;
}

function validatePhotos(body, allowOCR = false) {
  if (!isObject(body) || !hasOnlyKeys(body, ["photos"]) || !Array.isArray(body.photos)
      || body.photos.length < 1 || body.photos.length > MAX_PHOTOS) {
    throw new Failure(400, "invalid_request", "같은 제품의 사진 1~5장을 전송해 주세요.");
  }
  const ids = new Set();
  let totalBytes = 0;
  return body.photos.map(photo => {
    if (!isObject(photo) || !hasOnlyKeys(photo, allowOCR ? ["id", "role", "imageDataUrl", "ocrText"] : ["id", "role", "imageDataUrl"])
        || typeof photo.id !== "string" || !photo.id.length || photo.id.length > 100
        || photo.id !== photo.id.trim() || /[\u0000-\u001f\u007f]/.test(photo.id)
        || ids.has(photo.id)) {
      throw new Failure(400, "invalid_photo", "사진마다 고유한 id를 지정해 주세요.");
    }
    if (allowOCR && photo.ocrText !== undefined && (typeof photo.ocrText !== "string" || photo.ocrText.length > 1200
      || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(photo.ocrText))) {
      throw new Failure(400, "invalid_photo", "OCR 원문 형식을 확인해 주세요.");
    }
    ids.add(photo.id);
    const role = photo.role === undefined ? "detail" : photo.role;
    if (!PHOTO_ROLES.has(role)) {
      throw new Failure(400, "invalid_photo_role", "사진 역할은 front, back, label, detail, defect 중 하나여야 합니다.");
    }
    totalBytes += imageBytes(photo.imageDataUrl);
    if (totalBytes > MAX_TOTAL_PHOTO_BYTES) {
      throw new Failure(413, "photos_too_large", "사진의 전체 용량은 8MiB 이하여야 합니다.");
    }
    return { id: photo.id, role, imageDataUrl: photo.imageDataUrl,
      ...(allowOCR && photo.ocrText !== undefined ? { ocrText: photo.ocrText } : {}) };
  });
}

function validateLabelAutofill(body) {
  if (!isObject(body) || !hasOnlyKeys(body, ["photos", "labelCrops"]) || !Array.isArray(body.labelCrops)
    || body.labelCrops.length > 1) throw new Failure(400, "invalid_request", "라벨 크롭 요청을 확인해 주세요.");
  const photos = validatePhotos({ photos: body.photos });
  const crops = body.labelCrops.map(crop => {
    if (!isObject(crop) || !hasOnlyKeys(crop, ["id", "sourcePhotoId", "imageDataUrl", "ocrText"])
      || !photos.some(photo => photo.id === crop.sourcePhotoId)) throw new Failure(400, "invalid_photo", "라벨 원본 사진을 확인해 주세요.");
    const [validated] = validatePhotos({ photos: [{ id: crop.id, role: "label", imageDataUrl: crop.imageDataUrl, ocrText: crop.ocrText }] }, true);
    return { ...validated, sourcePhotoId: crop.sourcePhotoId };
  });
  if ([...photos, ...crops].reduce((total, photo) => total + imageBytes(photo.imageDataUrl), 0) > MAX_TOTAL_PHOTO_BYTES) {
    throw new Failure(413, "photos_too_large", "사진의 전체 용량은 8MiB 이하여야 합니다.");
  }
  return { photos, crops };
}

function validateLandmarkRequest(body) {
  if (!isObject(body) || !hasOnlyKeys(body, ["requestId", "image", "category"])
      || typeof body.requestId !== "string"
      || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(body.requestId)
      || !OUTERWEAR_CATEGORIES.has(body.category)
      || !isObject(body.image) || !hasOnlyKeys(body.image, ["imageDataUrl", "width", "height"])
      || ![body.image.width, body.image.height].every(value => Number.isInteger(value) && value > 0 && value <= 16384)) {
    throw new Failure(400, "invalid_request", "아우터 사진 한 장과 올바른 요청 정보를 전송해 주세요.");
  }
  imageBytes(body.image.imageDataUrl);
  return { requestId: body.requestId, category: body.category,
    image: { imageDataUrl: body.image.imageDataUrl, width: body.image.width, height: body.image.height } };
}

function upstreamFailure(status) {
  if (status === 429) return new Failure(503, "ai_rate_limited", "AI 요청이 많습니다. 잠시 후 다시 시도해 주세요.");
  if (status === 401 || status === 403) return new Failure(503, "ai_configuration_error", "AI 연결 서버 설정을 확인해 주세요.");
  return new Failure(502, "ai_request_failed", "AI 초안을 생성하지 못했습니다. 잠시 후 다시 시도해 주세요.");
}

function validateRefinementRequest(body, allowedRegions = REFINEMENT_REGIONS) {
  const neck = allowedRegions === NECK_REFINEMENT_REGIONS;
  const keys = neck ? ["requestId", "category", "image", "regions", "target"] : ["requestId", "category", "image", "regions"];
  if (!isObject(body) || !hasOnlyKeys(body, keys)
      || !Array.isArray(body.regions) || body.regions.length !== Object.keys(allowedRegions).length) {
    throw new Failure(400, "invalid_request", "확대 비교 요청을 확인해 주세요.");
  }
  if (neck && body.target !== undefined && !["neck_left", "neck_right"].includes(body.target)) {
    throw new Failure(400, "invalid_request", "목옆 확대 대상을 확인해 주세요.");
  }
  const input = validateLandmarkRequest({ requestId: body.requestId, category: body.category, image: body.image });
  let total = imageBytes(input.image.imageDataUrl);
  const ids = new Set();
  const regions = body.regions.map(region => {
    if (!isObject(region) || !hasOnlyKeys(region, ["id", "image"]) || typeof region.id !== "string"
        || !Object.hasOwn(allowedRegions, region.id) || ids.has(region.id)) {
      throw new Failure(400, "invalid_request", "확대 부위 정보를 확인해 주세요.");
    }
    ids.add(region.id);
    const validated = validateLandmarkRequest({ requestId: input.requestId, category: input.category, image: region.image });
    total += imageBytes(validated.image.imageDataUrl);
    return { id: region.id, image: validated.image };
  });
  if (total > MAX_TOTAL_PHOTO_BYTES) throw new Failure(413, "photos_too_large", "사진 전체 용량은 8MiB 이하여야 합니다.");
  return { ...input, regions, ...(neck && body.target !== undefined ? { target: body.target } : {}) };
}

async function generateAI(input, env, fetchImpl, timeoutMs, landmarkVersion = 0, refinement = false) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(OPENAI_RESPONSES_URL, {
      method: "POST",
      headers: { "Authorization": `Bearer ${env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify(refinement === "neck" ? buildNeckRefinementOpenAIRequest(input)
        : refinement === "length" ? buildLengthRefinementOpenAIRequest(input)
        : refinement ? buildRefinementOpenAIRequest(input, { version: landmarkVersion })
        : landmarkVersion ? buildLandmarkOpenAIRequest(input, { version: landmarkVersion }) : buildOpenAIRequest(input)),
      signal: controller.signal,
    });
    if (!response.ok) {
      try { await response.body?.cancel(); } catch { /* Do not read or relay upstream errors. */ }
      throw upstreamFailure(response.status);
    }
    let payload;
    try { payload = await response.json(); }
    catch {
      if (controller.signal.aborted) throw new Failure(504, "ai_timeout", "AI 응답 시간이 초과되었습니다. 다시 시도해 주세요.");
      throw new Failure(502, "invalid_ai_response", "AI 응답 형식을 확인할 수 없습니다.");
    }
    try {
      if (refinement === "neck") {
        const result = parseNeckRefinementOpenAIResponse(payload, input.requestId);
        if (input.target && Object.entries(result.points).some(([id, observation]) => id !== input.target && observation.point !== null)) {
          throw new Failure(502, "invalid_ai_response", "목옆 확대 응답을 확인할 수 없습니다.");
        }
        return result;
      }
      if (refinement === "length") return parseLengthRefinementOpenAIResponse(payload, input.requestId);
      if (refinement) return { refinementVersion: landmarkVersion === 4 ? REFINEMENT_VERSION_V4 : landmarkVersion === 3 ? REFINEMENT_VERSION_V3 : REFINEMENT_VERSION,
        localResponse: parseLandmarkOpenAIResponse(payload, input.requestId, { version: landmarkVersion }) };
      return landmarkVersion
        ? parseLandmarkOpenAIResponse(payload, input.requestId, { version: landmarkVersion }) : parseOpenAIResponse(payload);
    }
    catch (error) {
      if (error instanceof DraftResponseError && error.code === "UNUSABLE_PHOTOS") {
        throw new Failure(422, "photo_unusable", "사진에서 의류를 확인하기 어렵습니다. 제품 전체와 라벨이 선명한 사진을 추가해 주세요.");
      }
      throw new Failure(502, "invalid_ai_response", landmarkVersion
        ? "AI 측정점을 확인할 수 없습니다. 다시 시도해 주세요."
        : "AI 초안을 확인할 수 없습니다. 다시 시도해 주세요.");
    }
  } catch (error) {
    if (error instanceof Failure) throw error;
    if (controller.signal.aborted || error?.name === "AbortError" || error?.name === "TimeoutError") {
      throw new Failure(504, "ai_timeout", "AI 응답 시간이 초과되었습니다. 다시 시도해 주세요.");
    }
    throw new Failure(502, "ai_unavailable", "AI 서버에 연결하지 못했습니다. 다시 시도해 주세요.");
  } finally {
    clearTimeout(timeout);
  }
}

async function generateProductAutofill(photos, env, fetchImpl, timeoutMs, operation = runProductAutofill) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const started = Date.now();
  const stageTimings = {};
  let brandDecision = null;
  try {
    const requestResponse = async body => {
      const callStarted = Date.now();
      const stage = ({ garment_identification: "identification", garment_cropped_label_readings: "label",
        garment_brand_discovery: "search", garment_heritage: "search" })[body.text?.format?.name];
      try {
        if (controller.signal.aborted) throw new Failure(504, "ai_timeout", "AI 응답 시간이 초과되었습니다. 다시 시도해 주세요.");
        const response = await fetchImpl(OPENAI_RESPONSES_URL, {
          method: "POST",
          headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
          body: JSON.stringify(body), signal: controller.signal,
        });
        if (!response.ok) {
          if ((operation === locateBrandLabels || operation === readCroppedBrandLabels) && response.status === 400) {
            let failure;
            try { failure = (await response.json())?.error; } catch { /* Only allowlisted metadata is public. */ }
            const params = new Set(["text.format.schema", "text.format", "max_output_tokens", "reasoning.effort", "input", "model"]);
            const param = params.has(failure?.param) ? failure.param : "unknown_setting";
            const codes = new Set(["invalid_json_schema", "unsupported_parameter", "unsupported_value", "invalid_value"]);
            const code = codes.has(failure?.code) ? failure.code : "bad_request";
            throw new Failure(502, `label_request_${code}`, `라벨 요청 설정 확인 필요: ${param}`);
          }
          try { await response.body?.cancel(); } catch { /* Never expose upstream bodies. */ }
          throw upstreamFailure(response.status);
        }
        try { return await response.json(); }
        catch {
          if (controller.signal.aborted) throw new Failure(504, "ai_timeout", "AI 응답 시간이 초과되었습니다. 다시 시도해 주세요.");
          throw new Failure(502, "invalid_ai_response", "AI 응답 형식을 확인할 수 없습니다.");
        }
      } finally {
        if (stage) stageTimings[stage] = (stageTimings[stage] || 0) + Date.now() - callStarted;
      }
    };
    const result = await operation(photos, { requestResponse, onBrandDecision: decision => { brandDecision = decision; } });
    return result.draft ? { ...result, stageTimings: { ...stageTimings, server: Date.now() - started }, brandDecision } : result;
  } catch (error) {
    if (error instanceof Failure) throw error;
    if (error instanceof DraftResponseError) {
      if ((operation === locateBrandLabels || operation === readCroppedBrandLabels)) {
        const codes = new Set(["INVALID_LABEL_ACTIVITY", "INVALID_LABEL_REGIONS", "INVALID_LABEL_REGION", "INVALID_LABEL_BOX",
          "INVALID_LABEL_READINGS", "INVALID_LABEL_READING", "INVALID_LABEL_BRAND", "INCOMPLETE_MODEL_RESPONSE", "MODEL_REFUSAL"]);
        const code = codes.has(error.code) ? error.code.toLowerCase() : "invalid_label_response";
        throw new Failure(502, code, "라벨 분석 응답을 검증하지 못했습니다.");
      }
      if (error.code === "UNUSABLE_PHOTOS") {
        throw new Failure(422, "photo_unusable", "사진에서 의류를 확인하기 어렵습니다. 제품 전체와 라벨이 선명한 사진을 추가해 주세요.");
      }
      throw new Failure(502, "invalid_ai_response", "AI 초안을 확인할 수 없습니다. 다시 시도해 주세요.");
    }
    if (controller.signal.aborted || error?.name === "AbortError" || error?.name === "TimeoutError") {
      throw new Failure(504, "ai_timeout", "AI 응답 시간이 초과되었습니다. 다시 시도해 주세요.");
    }
    throw new Failure(502, "ai_unavailable", "AI 서버에 연결하지 못했습니다. 다시 시도해 주세요.");
  } finally {
    clearTimeout(timeout);
  }
}

export function createWorker({ fetchImpl = fetch, timeoutMs = 30000,
  autofillTimeoutMs = timeoutMs === 30000 ? 45000 : timeoutMs } = {}) {
  if (typeof fetchImpl !== "function" || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000
      || !Number.isInteger(autofillTimeoutMs) || autofillTimeoutMs < 1 || autofillTimeoutMs > 45000) {
    throw new TypeError("Invalid Worker dependencies.");
  }
  return {
    async fetch(request, env) {
      const requestId = crypto.randomUUID();
      try {
        const path = new URL(request.url).pathname;
        if (path === "/health" && request.method === "GET") {
          return json({ service: "dobby-garment-ai", status: "ok" }, 200, requestId);
        }
        if (!["/v1/garments/autofill-labels", "/v1/garments/brand-label-regions", "/v1/garments/brand-label-readings", "/v1/garments/autofill", "/v1/garments/landmarks", "/v2/garments/landmarks", "/v2/garments/landmark-refinement", "/v3/garments/landmarks", "/v3/garments/landmark-refinement", "/v4/garments/landmarks", "/v4/garments/landmark-refinement", "/v4/garments/length-refinement", "/v4/garments/neck-refinement", "/health"].includes(path)) {
          throw new Failure(404, "not_found", "요청 경로를 확인해 주세요.");
        }
        const method = path === "/health" ? "GET" : "POST";
        if (request.method !== method) {
          return json({ error: { code: "method_not_allowed", message: "지원하지 않는 요청 방식입니다." }, requestId },
            405, requestId, { Allow: method });
        }
        const authentication = await authorize(request, env);
        if (authentication.kind === "app") {
          await enforceAppUsageLimits(env, authentication.installationID);
        }
        const body = await readJSON(request);
        if (path === "/v1/garments/autofill-labels") {
          const { photos, crops } = validateLabelAutofill(body);
          const operation = (input, dependencies) => runProductAutofill(input, { ...dependencies, labelCrops: crops });
          const result = await generateProductAutofill(photos, env, fetchImpl, autofillTimeoutMs, operation);
          return json(result.draft, 200, requestId, autofillHeaders(result));
        }
        const refinement = path.endsWith("/neck-refinement") ? "neck" : path.endsWith("/length-refinement") ? "length" : path.endsWith("/landmark-refinement");
        const landmarkVersion = path.startsWith("/v4/") ? 4 : path.startsWith("/v3/") ? 3 : path.startsWith("/v2/") ? 2
          : path === "/v1/garments/landmarks" ? 1 : 0;
        const input = refinement ? validateRefinementRequest(body, refinement === "neck" ? NECK_REFINEMENT_REGIONS : refinement === "length" ? LENGTH_REFINEMENT_REGIONS : REFINEMENT_REGIONS)
          : landmarkVersion ? validateLandmarkRequest(body) : validatePhotos(body, path === "/v1/garments/brand-label-readings");
        if (path === "/v1/garments/brand-label-regions" || path === "/v1/garments/brand-label-readings") {
          const operation = path.endsWith("/brand-label-regions") ? locateBrandLabels : readCroppedBrandLabels;
          return json(await generateProductAutofill(input, env, fetchImpl, timeoutMs, operation), 200, requestId);
        }
        if (!landmarkVersion) {
          const result = await generateProductAutofill(input, env, fetchImpl, autofillTimeoutMs);
          return json(result.draft, 200, requestId, autofillHeaders(result));
        }
        return json(await generateAI(input, env, fetchImpl, timeoutMs, landmarkVersion, refinement), 200, requestId);
      } catch (error) {
        // Never log credentials, image data, model output, or raw upstream errors.
        return failureResponse(error, requestId);
      }
    },
  };
}

export default createWorker();
