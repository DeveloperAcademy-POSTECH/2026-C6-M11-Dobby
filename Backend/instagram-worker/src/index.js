const SCOPES = ["instagram_business_basic", "instagram_business_content_publish"];
const APP_CALLBACK = "dobby-copy://instagram/oauth";
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_COUNT = 10;
const MAX_TOTAL_IMAGE_BYTES = 40 * 1024 * 1024;
const MAX_BODY_BYTES = 64 * 1024 * 1024;
const CHILD_CONTAINER_CONCURRENCY = 5;
const CONTAINER_POLL_INTERVAL_MS = 2000;
const CONTAINER_POLL_MAX_ATTEMPTS = 5;
const DATA_DELETION_STATUS_TTL = 30 * 24 * 60 * 60;
const json = (body, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
function uploadTiming(request) {
  const path = request.headers.get("X-Dobby-Internal-Path") || new URL(request.url).pathname;
  const id = request.headers.get("X-Dobby-Upload-Timing") || "";
  if ((path !== "/account" && path !== "/publish") ||
      !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(id)) return undefined;
  return (stage, start, outcome, details = {}) => {
    console.log(JSON.stringify({
      event: "instagram_upload_timing", id, path, stage,
      durationMs: Math.round(performance.now() - start), outcome, ...details
    }));
  };
}

async function measureUploadStage(logTiming, stage, operation) {
  if (!logTiming) return operation();
  const start = performance.now();
  try {
    const result = await operation();
    logTiming(stage, start, "ok");
    return result;
  } catch (error) {
    logTiming(stage, start, "error");
    throw error;
  }
}

function logOAuth(flowID, stage, start, outcome, error) {
  console.log(JSON.stringify({
    event: "instagram_oauth",
    flowID,
    stage,
    durationMs: Math.round(performance.now() - start),
    outcome,
    ...(error?.code ? { code: error.code } : {})
  }));
}

async function measureOAuthStage(flowID, stage, operation) {
  const start = performance.now();
  try {
    const result = await operation();
    logOAuth(flowID, stage, start, "ok");
    return result;
  } catch (error) {
    logOAuth(flowID, stage, start, "error", error);
    throw error;
  }
}

class Failure extends Error {
  constructor(message, status = 400, code = undefined) { super(message); this.status = status; this.code = code; }
}
function randomToken() {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, "0")).join("");
}
async function hash(value) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, "0")).join("");
}
function base64URLBytes(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Failure("요청 서명을 확인할 수 없습니다.", 400);
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  try { return Uint8Array.from(atob(base64), character => character.charCodeAt(0)); }
  catch { throw new Failure("요청 서명을 확인할 수 없습니다.", 400); }
}
async function signedRequestUserID(request, appSecret) {
  if (!appSecret) throw new Failure("Instagram 로그인 서버 설정이 필요합니다.", 503);
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().includes("application/x-www-form-urlencoded")) {
    throw new Failure("요청 형식을 확인해 주세요.", 400);
  }
  const signedRequest = new URLSearchParams(await request.text()).get("signed_request") || "";
  const parts = signedRequest.split(".");
  if (parts.length !== 2) throw new Failure("요청 서명을 확인할 수 없습니다.", 400);
  const signature = base64URLBytes(parts[0]);
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(appSecret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]
  );
  const valid = await crypto.subtle.verify("HMAC", key, signature, new TextEncoder().encode(parts[1]));
  if (!valid) throw new Failure("요청 서명을 확인할 수 없습니다.", 401);
  let payload;
  try { payload = JSON.parse(new TextDecoder().decode(base64URLBytes(parts[1]))); }
  catch { throw new Failure("요청 내용을 확인할 수 없습니다.", 400); }
  if (String(payload.algorithm || "").toUpperCase() !== "HMAC-SHA256"
      || !/^\d+$/.test(String(payload.user_id || ""))) {
    throw new Failure("요청 내용을 확인할 수 없습니다.", 400);
  }
  return String(payload.user_id);
}
function origin(env) {
  const url = new URL(env.PUBLIC_BASE_URL);
  if (url.protocol !== "https:" || url.hostname.includes("YOUR-")) throw new Failure("서버 주소 설정을 확인해 주세요.", 503);
  return url.origin;
}
function graphURL(env, path) {
  if (!/^v\d+\.\d+$/.test(env.INSTAGRAM_API_VERSION)) throw new Failure("Instagram API 버전 설정이 필요합니다.", 503);
  return new URL(`https://graph.instagram.com/${env.INSTAGRAM_API_VERSION}/${path}`);
}
function redirect(status, attempt) {
  const url = new URL(APP_CALLBACK);
  url.searchParams.set("status", status);
  url.searchParams.set("attempt", attempt);
  return new Response(null, { status: 302, headers: { Location: url.href, "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" } });
}
function oauthTokenErrorReason(data) {
  const message = String(data?.error?.message || data?.error_message || "").toLowerCase();
  if (message.includes("client secret") || message.includes("client_secret")) return "invalid_client_secret";
  if (message.includes("redirect") && message.includes("uri")) return "redirect_uri_mismatch";
  if (message.includes("code")
      && ["invalid", "used", "expired", "matching", "authorization"].some(value => message.includes(value))) {
    return "code_invalid_or_used";
  }
  return "upstream_rejected";
}
function safeMetaErrorType(data) {
  const type = data?.error?.type || data?.error_type;
  return typeof type === "string" && /^[A-Za-z0-9_.-]{1,64}$/.test(type) ? type : undefined;
}
function shortTokenResponseShape(response) {
  if (Array.isArray(response?.data)) return "data_envelope";
  if (response && typeof response === "object"
      && (Object.hasOwn(response, "access_token") || Object.hasOwn(response, "user_id"))) return "top_level";
  return "unknown";
}
function logOAuthTokenDiagnostic(flowID, details) {
  const log = details.outcome === "error" ? console.error : console.log;
  log(JSON.stringify({ event: "instagram_oauth_token_diagnostic", flowID, stage: "short_token_exchange", ...details }));
}
async function upstream(url, options = {}, oauthFlowID) {
  let response;
  try { response = await fetch(url, { ...options, signal: AbortSignal.timeout(20000) }); }
  catch {
    if (oauthFlowID) logOAuthTokenDiagnostic(oauthFlowID, { outcome: "error", reason: "network_error" });
    throw new Failure("Instagram 응답을 받지 못했습니다. 게시 요청이었다면 계정에서 결과를 먼저 확인해 주세요.", 502);
  }
  let data;
  try { data = await response.json(); } catch {
    if (oauthFlowID) {
      logOAuthTokenDiagnostic(oauthFlowID, {
        outcome: "error", httpStatus: response.status, responseShape: "unknown", reason: "invalid_response_shape"
      });
    }
    throw new Failure("Instagram 응답 형식을 확인할 수 없습니다.", 502);
  }
  if (!response.ok || data.error || data.error_type) {
    const rawCode = data.error?.code ?? data.code;
    const code = Number.isInteger(Number(rawCode)) ? Number(rawCode) : undefined;
    // Never log URLs, raw upstream errors, access tokens or authorization codes.
    if (oauthFlowID) {
      logOAuthTokenDiagnostic(oauthFlowID, {
        outcome: "error", httpStatus: response.status, metaCode: code,
        metaType: safeMetaErrorType(data), reason: oauthTokenErrorReason(data)
      });
    } else {
      console.error(JSON.stringify({ event: "instagram_api_error", status: response.status, code, subcode: data.error?.error_subcode, traceID: data.error?.fbtrace_id }));
    }
    throw new Failure(code === 190 ? "Instagram 연결이 만료되었습니다. 다시 연결해 주세요."
      : `Instagram 요청에 실패했습니다.${code ? ` (오류 코드 ${code})` : ""}`, code === 190 ? 401 : 502, code);
  }
  return data;
}
function shortLivedToken(response, flowID) {
  const responseShape = shortTokenResponseShape(response);
  const token = responseShape === "data_envelope" && response.data.length === 1
    ? response.data[0]
    : responseShape === "top_level" ? response : undefined;
  const userID = String(token?.user_id || "");
  const valid = typeof token?.access_token === "string" && Boolean(token.access_token) && /^\d+$/.test(userID);
  logOAuthTokenDiagnostic(flowID, {
    outcome: valid ? "ok" : "error", httpStatus: 200, responseShape,
    ...(valid ? {} : { reason: "invalid_response_shape" })
  });
  if (!valid) {
    throw new Failure("Instagram 인증 토큰 응답을 확인할 수 없습니다.", 502);
  }
  return { accessToken: token.access_token, userID };
}
function authorized(token) { return { Authorization: `Bearer ${token}` }; }
async function fetchAccount(env, token) {
  const me = graphURL(env, "me");
  me.searchParams.set("fields", "user_id,username,account_type,profile_picture_url");
  const profile = await upstream(me, { headers: authorized(token) });
  if (!profile.user_id || !profile.username
      || !["BUSINESS", "MEDIA_CREATOR", "CREATOR"].includes(profile.account_type)) {
    throw new Failure("프로페셔널 계정이 필요합니다.");
  }
  return {
    id: String(profile.user_id),
    username: profile.username,
    profilePictureURL: typeof profile.profile_picture_url === "string" ? profile.profile_picture_url : null
  };
}
function decodeImages(body) {
  const encoded = Array.isArray(body.imagesBase64)
    ? body.imagesBase64
    : typeof body.imageBase64 === "string" ? [body.imageBase64] : [];
  if (encoded.length === 0) throw new Failure("게시할 사진이 필요합니다.");
  if (encoded.length > MAX_IMAGE_COUNT) throw new Failure("Instagram에는 사진을 최대 10장까지 게시할 수 있습니다.");
  let totalBytes = 0;
  const images = encoded.map(value => {
    if (typeof value !== "string" || value.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4) {
      throw new Failure("사진 용량을 확인해 주세요.", 413);
    }
    let bytes;
    try { bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0)); }
    catch { throw new Failure("사진 형식이 올바르지 않습니다."); }
    if (bytes.length < 3 || bytes.length > MAX_IMAGE_BYTES
        || bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255) {
      throw new Failure("JPEG 사진이 필요합니다.");
    }
    totalBytes += bytes.length;
    if (totalBytes > MAX_TOTAL_IMAGE_BYTES) throw new Failure("사진 전체 용량이 너무 큽니다.", 413);
    return bytes;
  });
  return { encoded, images };
}
async function createContainer(env, connection, parameters) {
  const media = await upstream(graphURL(env, `${connection.account.id}/media`), {
    method: "POST", headers: authorized(connection.token), body: new URLSearchParams(parameters)
  });
  if (!media.id) throw new Failure("게시 컨테이너를 확인할 수 없습니다.", 502);
  return String(media.id);
}
async function createChildContainers(env, connection, imageURLs) {
  const childIDs = [];
  for (let startIndex = 0; startIndex < imageURLs.length; startIndex += CHILD_CONTAINER_CONCURRENCY) {
    const imageURLBatch = imageURLs.slice(startIndex, startIndex + CHILD_CONTAINER_CONCURRENCY);
    const batchIDs = await Promise.all(imageURLBatch.map(imageURL =>
      createContainer(env, connection, { image_url: imageURL, is_carousel_item: "true" })
    ));
    childIDs.push(...batchIDs);
  }
  return childIDs;
}
async function waitUntilReady(env, token, containerID, logTiming, stage, photoIndex) {
  const start = performance.now();
  const check = graphURL(env, containerID); check.searchParams.set("fields", "status_code");
  let pollCount = 0;
  let outcome = "error";
  try {
    let status;
    for (let attempt = 0; attempt < CONTAINER_POLL_MAX_ATTEMPTS; attempt++) {
      pollCount++;
      status = await upstream(check, { headers: authorized(token) });
      if (status.status_code !== "IN_PROGRESS") break;
      if (attempt < CONTAINER_POLL_MAX_ATTEMPTS - 1) {
        await new Promise(resolve => setTimeout(resolve, CONTAINER_POLL_INTERVAL_MS));
      }
    }
    if (status?.status_code !== "FINISHED") {
      throw new Failure("사진 처리가 완료되지 않았습니다. 잠시 후 다시 시도해 주세요.", 409);
    }
    outcome = "ok";
  } finally {
    logTiming?.(stage, start, outcome, { pollCount, photoIndex });
  }
}
async function readBody(request) {
  if (Number(request.headers.get("content-length")) > MAX_BODY_BYTES) throw new Failure("사진 용량이 너무 큽니다.", 413);
  const reader = request.body?.getReader();
  if (!reader) throw new Failure("요청 내용이 없습니다.");
  const chunks = []; let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) { await reader.cancel(); throw new Failure("사진 용량이 너무 큽니다.", 413); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Failure("요청 형식이 올바르지 않습니다."); }
}
function failureResponse(error) {
  console.error(JSON.stringify({ event: "request_failed", type: error instanceof Failure ? "handled" : "unexpected", status: error.status || 500 }));
  return json({ message: error instanceof Failure ? error.message : "서버 처리 중 오류가 발생했습니다.", code: error.code }, error.status || 500);
}
function connectionRequest(request, url, headers = request.headers) {
  const internalHeaders = new Headers(headers);
  internalHeaders.set("X-Dobby-Internal-Path", url.pathname);
  internalHeaders.set("X-Dobby-Internal-Search", url.search);
  const internal = new Request("https://instagram-connection.internal/", request);
  return new Request(internal, { headers: internalHeaders });
}
function internalRequest(path, body) {
  return new Request(`https://instagram-connection.internal${path}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
  });
}
async function updateAccountIndex(env, action, userID, owner) {
  if (!userID || !owner) return;
  const accountHash = await hash(userID);
  const target = env.INSTAGRAM_ACCOUNT_CONNECTIONS.get(env.INSTAGRAM_ACCOUNT_CONNECTIONS.idFromName(accountHash));
  const response = await target.fetch(internalRequest(`/${action}`, { owner }));
  if (!response.ok) throw new Failure("Instagram 연결 정보를 정리하지 못했습니다.", 503);
}
async function processMetaCallback(request, env, deletion) {
  const userID = await signedRequestUserID(request, env.INSTAGRAM_APP_SECRET);
  const accountHash = await hash(userID);
  const target = env.INSTAGRAM_ACCOUNT_CONNECTIONS.get(env.INSTAGRAM_ACCOUNT_CONNECTIONS.idFromName(accountHash));
  const response = await target.fetch(internalRequest(deletion ? "/delete" : "/deauthorize", { userID }));
  if (!response.ok) throw new Failure("Instagram 연결 정보를 정리하지 못했습니다.", 503);
  if (!deletion) return json({ deauthorized: true });
  const result = await response.json();
  await env.INSTAGRAM_MEDIA.put(`deletion-status:${result.confirmationCode}`, JSON.stringify({ completed: true }), {
    expirationTtl: DATA_DELETION_STATUS_TTL
  });
  return json({
    url: `${origin(env)}/data-deletion/status/${result.confirmationCode}`,
    confirmation_code: result.confirmationCode
  });
}
function deletionStatusPage(found) {
  const title = found ? "데이터 삭제가 완료되었습니다" : "삭제 요청을 찾을 수 없습니다";
  const description = found
    ? "chak의 Instagram 연결 정보와 서버에 저장된 관련 데이터가 삭제되었습니다."
    : "확인 코드가 만료되었거나 올바르지 않습니다.";
  return new Response(`<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title><body><main><h1>${title}</h1><p>${description}</p></main></body></html>`, {
    status: found ? 200 : 404,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" }
  });
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/" && request.method === "GET") return json({ service: "dobby-instagram", oauth: true });
      if (url.pathname === "/oauth/deauthorize" && request.method === "POST") {
        return await processMetaCallback(request, env, false);
      }
      if (url.pathname === "/oauth/data-deletion" && request.method === "POST") {
        return await processMetaCallback(request, env, true);
      }
      const deletionStatus = url.pathname.match(/^\/data-deletion\/status\/([a-f0-9]{64})$/);
      if (deletionStatus && request.method === "GET") {
        return deletionStatusPage(Boolean(await env.INSTAGRAM_MEDIA.get(`deletion-status:${deletionStatus[1]}`)));
      }
      if (/^\/media\/[a-f0-9]{64}\.jpg$/.test(url.pathname) && request.method === "GET") {
        const data = await env.INSTAGRAM_MEDIA.get(url.pathname.slice(7), "arrayBuffer");
        return data ? new Response(data, { headers: { "Content-Type": "image/jpeg", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }) : json({ message: "사진이 만료되었습니다." }, 404);
      }
      if (url.pathname === "/oauth/callback" && request.method === "GET") {
        const state = url.searchParams.get("state") || "";
        if (!/^[a-f0-9]{64}\.[a-f0-9]{64}$/.test(state)) return json({ message: "유효하지 않은 로그인 요청입니다." }, 400);
        return env.INSTAGRAM_CONNECTIONS.get(env.INSTAGRAM_CONNECTIONS.idFromName(state.split(".")[0]))
          .fetch(connectionRequest(request, url));
      }
      if (!env.DOBBY_APP_API_KEY) throw new Failure("서버 앱 접근 키 설정이 필요합니다.", 503);
      if (await hash(request.headers.get("X-Dobby-App-Key") || "") !== await hash(env.DOBBY_APP_API_KEY)) return json({ message: "앱 접근 키를 확인해 주세요." }, 401);
      const bearer = request.headers.get("Authorization") || "";
      if (!/^Bearer [a-f0-9]{64}$/.test(bearer)) return json({ message: "앱 연결 정보를 확인해 주세요." }, 401);
      if (![["POST", "/oauth/start"], ["GET", "/account"], ["POST", "/disconnect"], ["POST", "/publish"]].some(([m, p]) => m === request.method && p === url.pathname)) return json({ message: "요청 경로를 확인해 주세요." }, 404);
      const owner = await hash(bearer.slice(7));
      const headers = new Headers(request.headers);
      headers.set("X-Connection-Owner", owner);
      return env.INSTAGRAM_CONNECTIONS.get(env.INSTAGRAM_CONNECTIONS.idFromName(owner))
        .fetch(connectionRequest(request, url, headers));
    } catch (error) { return failureResponse(error); }
  }
};

// One strongly consistent index per Instagram user; maps Meta callbacks to every linked installation.
export class InstagramAccountConnections {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; this.queue = Promise.resolve(); }
  async fetch(request) {
    const operation = this.queue.then(() => this.route(request));
    this.queue = operation.then(() => {}, () => {});
    try { return await operation; } catch (error) { return failureResponse(error); }
  }
  async route(request) {
    if (request.method !== "POST") return json({ message: "요청 경로를 확인해 주세요." }, 404);
    const path = new URL(request.url).pathname;
    const body = await request.json();
    const storage = this.ctx.storage;
    const owners = new Set(await storage.get("owners") || []);
    if (path === "/add") {
      if (!/^[a-f0-9]{64}$/.test(body.owner || "")) throw new Failure("연결 식별자를 확인해 주세요.");
      owners.add(body.owner);
      await storage.put("owners", [...owners]);
      return json({ indexed: true });
    }
    if (path === "/remove") {
      owners.delete(body.owner);
      if (owners.size) await storage.put("owners", [...owners]);
      else await storage.delete("owners");
      return json({ indexed: false });
    }
    if ((path === "/deauthorize" || path === "/delete") && /^\d+$/.test(body.userID || "")) {
      const results = await Promise.all([...owners].map(async owner => {
        const id = owner.startsWith("object:")
          ? this.env.INSTAGRAM_CONNECTIONS.idFromString(owner.slice(7))
          : this.env.INSTAGRAM_CONNECTIONS.idFromName(owner);
        const target = this.env.INSTAGRAM_CONNECTIONS.get(id);
        return target.fetch(internalRequest("/meta-delete", { userID: body.userID }));
      }));
      if (results.some(response => !response.ok)) throw new Failure("연결 데이터 일부를 정리하지 못했습니다.", 503);
      await storage.delete("owners");
      if (path === "/deauthorize") return json({ deauthorized: true });
      const existing = await storage.get("deletion");
      if (existing?.confirmationCode) return json(existing);
      const deletion = { confirmationCode: randomToken(), completedAt: Date.now() };
      await storage.put("deletion", deletion);
      return json(deletion);
    }
    return json({ message: "요청 경로를 확인해 주세요." }, 404);
  }
}

// One strongly consistent object per app installation; no Instagram token leaves this object.
export class InstagramConnection {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; this.queue = Promise.resolve(); }
  async fetch(request) {
    // Serialize callback/disconnect/publish so switching accounts cannot race a publication.
    const logTiming = this.env.INSTAGRAM_UPLOAD_TIMING === "true" ? uploadTiming(request) : undefined;
    const start = performance.now();
    const operation = this.queue.then(async () => {
      logTiming?.("queue_wait", start, "ok");
      let response;
      try { response = await this.route(request, logTiming); } catch (error) { response = failureResponse(error); }
      logTiming?.("worker_total", start, `http_${response.status}`);
      return response;
    });
    this.queue = operation.then(() => {}, () => {});
    return operation;
  }
  async route(request, logTiming) {
    const url = new URL(request.url), storage = this.ctx.storage, env = this.env;
    const path = request.headers.get("X-Dobby-Internal-Path") || url.pathname;
    const params = new URLSearchParams(request.headers.get("X-Dobby-Internal-Search") || url.search);
    if (path === "/oauth/start") {
      if (!env.INSTAGRAM_APP_ID || !env.INSTAGRAM_APP_SECRET) throw new Failure("Instagram 로그인 서버 설정이 필요합니다.", 503);
      const start = performance.now();
      const attempt = randomToken();
      const flowID = attempt.slice(0, 12);
      const state = `${request.headers.get("X-Connection-Owner")}.${randomToken()}`;
      await storage.put("pending", { state, attempt, expires: Date.now() + 10 * 60 * 1000 });
      const auth = new URL("https://www.instagram.com/oauth/authorize");
      auth.search = new URLSearchParams({ client_id: env.INSTAGRAM_APP_ID, redirect_uri: `${origin(env)}/oauth/callback`, response_type: "code", scope: SCOPES.join(","), state, enable_fb_login: "0", force_reauth: "true" }).toString();
      logOAuth(flowID, "oauth_start", start, "ok");
      return json({ authorizationURL: auth.href, attempt });
    }
    if (path === "/oauth/callback") {
      const pending = await storage.get("pending");
      if (!pending || pending.state !== params.get("state") || pending.expires < Date.now()) return json({ message: "로그인 요청이 만료되었거나 이미 사용되었습니다. 앱에서 다시 연결해 주세요." }, 400);
      const flowID = pending.attempt.slice(0, 12);
      logOAuth(flowID, "oauth_callback_received", performance.now(), "ok");
      await storage.delete("pending"); // Consume once, including denial/failure.
      if (params.has("error")) return redirect("denied", pending.attempt);
      const code = params.get("code");
      if (!code) return redirect("failed", pending.attempt);
      try {
        const short = await measureOAuthStage(flowID, "short_token_exchange", async () => {
          const response = await upstream("https://api.instagram.com/oauth/access_token", { method: "POST", body: new URLSearchParams({ client_id: env.INSTAGRAM_APP_ID, client_secret: env.INSTAGRAM_APP_SECRET, grant_type: "authorization_code", redirect_uri: `${origin(env)}/oauth/callback`, code }) }, flowID);
          return shortLivedToken(response, flowID);
        });
        const exchange = new URL("https://graph.instagram.com/access_token");
        exchange.search = new URLSearchParams({ grant_type: "ig_exchange_token", client_secret: env.INSTAGRAM_APP_SECRET, access_token: short.accessToken }).toString();
        const long = await measureOAuthStage(flowID, "long_token_exchange", async () => {
          const result = await upstream(exchange);
          if (!result.access_token || !(result.expires_in > 0)) throw new Failure("토큰 교환에 실패했습니다.");
          return result;
        });
        const account = await measureOAuthStage(flowID, "account_fetch", () =>
          fetchAccount(env, long.access_token)
        );
        const metaUserID = short.userID;
        if (!/^\d+$/.test(metaUserID)) throw new Failure("Instagram 사용자 정보를 확인할 수 없습니다.", 502);
        const owner = pending.state.split(".")[0];
        const previous = await storage.get("connection");
        await measureOAuthStage(flowID, "connection_saved", async () => {
          await updateAccountIndex(env, "add", metaUserID, owner);
          await storage.put("connection", { token: long.access_token, expires: Date.now() + long.expires_in * 1000, refreshed: Date.now(), metaUserID, owner, account });
        });
        if (previous?.metaUserID && previous.metaUserID !== metaUserID) {
          await updateAccountIndex(env, "remove", previous.metaUserID, owner);
        }
        logOAuth(flowID, "oauth_completed", performance.now(), "ok");
        return redirect("success", pending.attempt);
      } catch (error) {
        console.error(JSON.stringify({ event: "oauth_failed", flowID, code: error.code, status: error.status || 500 }));
        return redirect("failed", pending.attempt);
      }
    }
    if (path === "/disconnect") {
      const connection = await storage.get("connection");
      await storage.deleteAll();
      if (connection?.metaUserID) {
        try { await updateAccountIndex(env, "remove", connection.metaUserID, request.headers.get("X-Connection-Owner")); }
        catch { console.error(JSON.stringify({ event: "account_index_remove_failed" })); }
      }
      return json({ disconnected: true });
    }
    if (path === "/meta-delete") {
      const body = await request.json();
      const connection = await storage.get("connection");
      if (connection && (connection.metaUserID === body.userID || connection.account?.id === body.userID)) {
        await storage.deleteAll();
      }
      return json({ deleted: true });
    }
    let connection = await storage.get("connection");
    if (!connection || connection.expires <= Date.now()) {
      if (connection) await storage.delete("connection");
      if (path === "/account") return json({ connected: false, account: null, connectionMode: "oauth" });
      throw new Failure("Instagram 계정을 먼저 연결해 주세요.", 401);
    }
    // Refresh on use, only after the token is at least 24 hours old.
    if (connection.expires - Date.now() < 7 * 86400000 && Date.now() - connection.refreshed > 86400000) {
      const refresh = new URL("https://graph.instagram.com/refresh_access_token");
      refresh.search = new URLSearchParams({ grant_type: "ig_refresh_token", access_token: connection.token }).toString();
      const token = await measureUploadStage(logTiming, "token_refresh", () => upstream(refresh));
      if (!token.access_token || !(token.expires_in > 0)) throw new Failure("다시 로그인해 주세요.", 401);
      connection = { ...connection, token: token.access_token, expires: Date.now() + token.expires_in * 1000, refreshed: Date.now() };
      await storage.put("connection", connection);
    }
    if (path === "/account") {
      const account = await measureUploadStage(logTiming, "meta_account", () =>
        fetchAccount(env, connection.token)
      );
      connection = { ...connection, account };
      await storage.put("connection", connection);
      return json({ connected: true, account, connectionMode: "oauth" });
    }
    if (path === "/publish") {
      const body = await measureUploadStage(logTiming, "read_body", () => readBody(request));
      if (body.accountID !== connection.account.id) throw new Failure("연결된 계정이 변경되었습니다. 다시 확인해 주세요.", 409);
      if (typeof body.caption !== "string" || !body.caption.trim() || body.caption.length > 2200) throw new Failure("게시물 내용은 1~2,200자로 입력해 주세요.");
      if (typeof body.requestID !== "string" || !/^[a-f0-9-]{36}$/i.test(body.requestID)) throw new Failure("게시 요청 식별자가 필요합니다.");
      const { encoded, images } = decodeImages(body);
      const publicationKey = `publication:${body.requestID}`;
      const fingerprint = await hash(JSON.stringify([body.accountID, body.caption, encoded]));
      const previous = await storage.get(publicationKey);
      if (previous?.requestID === body.requestID) {
        if (previous.fingerprint !== fingerprint) throw new Failure("이전 게시 요청과 내용이 다릅니다. 결과를 확인하고 화면을 다시 열어 주세요.", 409);
        if (previous.result) return json(previous.result);
        throw new Failure("이미 처리한 요청입니다. Instagram에서 게시 결과를 확인해 주세요.", 409);
      }
      const keys = images.map(() => `${randomToken()}.jpg`);
      await measureUploadStage(logTiming, "store_images", () =>
        Promise.all(keys.map((key, index) => env.INSTAGRAM_MEDIA.put(key, images[index], { expirationTtl: 3600 })))
      );
      // Mark before any publish-side effects; retrying this ID must not create another post.
      await storage.put(publicationKey, { requestID: body.requestID, fingerprint });
      let publishing = false;
      try {
        const imageURLs = keys.map(key => `${origin(env)}/media/${key}`);
        let publishContainerID;
        if (imageURLs.length === 1) {
          publishContainerID = await measureUploadStage(logTiming, "create_single_container", () =>
            createContainer(env, connection, { image_url: imageURLs[0], caption: body.caption.trim() })
          );
          await waitUntilReady(env, connection.token, publishContainerID, logTiming, "single_container_ready");
        } else {
          const childIDs = await measureUploadStage(logTiming, "create_child_containers", () =>
            createChildContainers(env, connection, imageURLs)
          );
          await measureUploadStage(logTiming, "child_containers_ready", () =>
            Promise.all(childIDs.map((id, index) =>
              waitUntilReady(env, connection.token, id, logTiming, "child_container_ready", index + 1)
            ))
          );
          publishContainerID = await measureUploadStage(logTiming, "create_carousel_container", () =>
            createContainer(env, connection, {
              media_type: "CAROUSEL", children: childIDs.join(","), caption: body.caption.trim()
            })
          );
          await waitUntilReady(env, connection.token, publishContainerID, logTiming, "carousel_container_ready");
        }
        publishing = true;
        const published = await measureUploadStage(logTiming, "media_publish", () =>
          upstream(graphURL(env, `${connection.account.id}/media_publish`), {
            method: "POST",
            headers: authorized(connection.token),
            body: new URLSearchParams({ creation_id: publishContainerID })
          })
        );
        if (!published.id) throw new Failure("게시 결과를 확인하지 못했습니다. Instagram에서 확인해 주세요.", 502);
        const result = { published: true, mediaID: String(published.id), username: connection.account.username };
        await storage.put(publicationKey, { requestID: body.requestID, fingerprint, result });
        return json(result);
      } catch (error) {
        // Container creation is not public. A failure before media_publish is safe to retry.
        if (!publishing) await storage.delete(publicationKey);
        throw error;
      } finally {
        await Promise.all(keys.map(key => env.INSTAGRAM_MEDIA.delete?.(key))).catch(() => {
          console.error(JSON.stringify({ event: "temporary_media_cleanup_failed" }));
        });
      }
    }
    return json({ message: "요청 경로를 확인해 주세요." }, 404);
  }
}
