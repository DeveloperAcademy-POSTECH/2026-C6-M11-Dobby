const SCOPES = ["instagram_business_basic", "instagram_business_content_publish"];
const APP_CALLBACK = "dobby-copy://instagram/oauth";
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_COUNT = 10;
const MAX_TOTAL_IMAGE_BYTES = 40 * 1024 * 1024;
const MAX_BODY_BYTES = 64 * 1024 * 1024;
const json = (body, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
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
async function upstream(url, options = {}) {
  let response;
  try { response = await fetch(url, { ...options, signal: AbortSignal.timeout(20000) }); }
  catch { throw new Failure("Instagram 응답을 받지 못했습니다. 게시 요청이었다면 계정에서 결과를 먼저 확인해 주세요.", 502); }
  let data;
  try { data = await response.json(); } catch { throw new Failure("Instagram 응답 형식을 확인할 수 없습니다.", 502); }
  if (!response.ok || data.error || data.error_type) {
    const code = data.error?.code;
    // Never log URLs, raw upstream errors, access tokens or authorization codes.
    console.error(JSON.stringify({ event: "instagram_api_error", status: response.status, code, subcode: data.error?.error_subcode, traceID: data.error?.fbtrace_id }));
    throw new Failure(code === 190 ? "Instagram 연결이 만료되었습니다. 다시 연결해 주세요."
      : `Instagram 요청에 실패했습니다.${code ? ` (오류 코드 ${code})` : ""}`, code === 190 ? 401 : 502, code);
  }
  return data;
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
async function waitUntilReady(env, token, containerID) {
  const check = graphURL(env, containerID); check.searchParams.set("fields", "status_code");
  let status;
  for (let attempt = 0; attempt < 5; attempt++) {
    status = await upstream(check, { headers: authorized(token) });
    if (status.status_code !== "IN_PROGRESS") break;
    await new Promise(resolve => setTimeout(resolve, 2000));
  }
  if (status?.status_code !== "FINISHED") {
    throw new Failure("사진 처리가 완료되지 않았습니다. 잠시 후 다시 시도해 주세요.", 409);
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

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (url.pathname === "/" && request.method === "GET") return json({ service: "dobby-instagram", oauth: true });
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

// One strongly consistent object per app installation; no Instagram token leaves this object.
export class InstagramConnection {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; this.queue = Promise.resolve(); }
  async fetch(request) {
    // Serialize callback/disconnect/publish so switching accounts cannot race a publication.
    const operation = this.queue.then(async () => {
      try { return await this.route(request); } catch (error) { return failureResponse(error); }
    });
    this.queue = operation.then(() => {}, () => {});
    return operation;
  }
  async route(request) {
    const url = new URL(request.url), storage = this.ctx.storage, env = this.env;
    const path = request.headers.get("X-Dobby-Internal-Path") || url.pathname;
    const params = new URLSearchParams(request.headers.get("X-Dobby-Internal-Search") || url.search);
    if (path === "/oauth/start") {
      if (!env.INSTAGRAM_APP_ID || !env.INSTAGRAM_APP_SECRET) throw new Failure("Instagram 로그인 서버 설정이 필요합니다.", 503);
      const attempt = randomToken();
      const state = `${request.headers.get("X-Connection-Owner")}.${randomToken()}`;
      await storage.put("pending", { state, attempt, expires: Date.now() + 10 * 60 * 1000 });
      const auth = new URL("https://www.instagram.com/oauth/authorize");
      auth.search = new URLSearchParams({ client_id: env.INSTAGRAM_APP_ID, redirect_uri: `${origin(env)}/oauth/callback`, response_type: "code", scope: SCOPES.join(","), state, enable_fb_login: "0", force_authentication: "1" }).toString();
      return json({ authorizationURL: auth.href, attempt });
    }
    if (path === "/oauth/callback") {
      const pending = await storage.get("pending");
      if (!pending || pending.state !== params.get("state") || pending.expires < Date.now()) return json({ message: "로그인 요청이 만료되었거나 이미 사용되었습니다. 앱에서 다시 연결해 주세요." }, 400);
      await storage.delete("pending"); // Consume once, including denial/failure.
      if (params.has("error")) return redirect("denied", pending.attempt);
      const code = params.get("code");
      if (!code) return redirect("failed", pending.attempt);
      try {
        const short = await upstream("https://api.instagram.com/oauth/access_token", { method: "POST", body: new URLSearchParams({ client_id: env.INSTAGRAM_APP_ID, client_secret: env.INSTAGRAM_APP_SECRET, grant_type: "authorization_code", redirect_uri: `${origin(env)}/oauth/callback`, code }) });
        if (!short.access_token) throw new Failure("인증 토큰이 없습니다.");
        const exchange = new URL("https://graph.instagram.com/access_token");
        exchange.search = new URLSearchParams({ grant_type: "ig_exchange_token", client_secret: env.INSTAGRAM_APP_SECRET, access_token: short.access_token }).toString();
        const long = await upstream(exchange);
        if (!long.access_token || !(long.expires_in > 0)) throw new Failure("토큰 교환에 실패했습니다.");
        const account = await fetchAccount(env, long.access_token);
        await storage.put("connection", { token: long.access_token, expires: Date.now() + long.expires_in * 1000, refreshed: Date.now(), account });
        return redirect("success", pending.attempt);
      } catch (error) {
        console.error(JSON.stringify({ event: "oauth_failed", code: error.code, status: error.status || 500 }));
        return redirect("failed", pending.attempt);
      }
    }
    if (path === "/disconnect") {
      await storage.deleteAll();
      return json({ disconnected: true });
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
      const token = await upstream(refresh);
      if (!token.access_token || !(token.expires_in > 0)) throw new Failure("다시 로그인해 주세요.", 401);
      connection = { ...connection, token: token.access_token, expires: Date.now() + token.expires_in * 1000, refreshed: Date.now() };
      await storage.put("connection", connection);
    }
    if (path === "/account") {
      const account = await fetchAccount(env, connection.token);
      connection = { ...connection, account };
      await storage.put("connection", connection);
      return json({ connected: true, account, connectionMode: "oauth" });
    }
    if (path === "/publish") {
      const body = await readBody(request);
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
      await Promise.all(keys.map((key, index) => env.INSTAGRAM_MEDIA.put(key, images[index], { expirationTtl: 3600 })));
      // Mark before any publish-side effects; retrying this ID must not create another post.
      await storage.put(publicationKey, { requestID: body.requestID, fingerprint });
      let publishing = false;
      try {
      const imageURLs = keys.map(key => `${origin(env)}/media/${key}`);
      let publishContainerID;
      if (imageURLs.length === 1) {
        publishContainerID = await createContainer(env, connection, {
          image_url: imageURLs[0], caption: body.caption.trim()
        });
        await waitUntilReady(env, connection.token, publishContainerID);
      } else {
        const childIDs = [];
        for (const imageURL of imageURLs) {
          childIDs.push(await createContainer(env, connection, {
            image_url: imageURL, is_carousel_item: "true"
          }));
        }
        await Promise.all(childIDs.map(id => waitUntilReady(env, connection.token, id)));
        publishContainerID = await createContainer(env, connection, {
          media_type: "CAROUSEL", children: childIDs.join(","), caption: body.caption.trim()
        });
        await waitUntilReady(env, connection.token, publishContainerID);
      }
      publishing = true;
      const published = await upstream(graphURL(env, `${connection.account.id}/media_publish`), { method: "POST", headers: authorized(connection.token), body: new URLSearchParams({ creation_id: publishContainerID }) });
      if (!published.id) throw new Failure("게시 결과를 확인하지 못했습니다. Instagram에서 확인해 주세요.", 502);
      const result = { published: true, mediaID: String(published.id), username: connection.account.username };
      await storage.put(publicationKey, { requestID: body.requestID, fingerprint, result });
      return json(result);
      } catch (error) {
        // Container creation is not public. A failure before media_publish is safe to retry.
        if (!publishing) await storage.delete(publicationKey);
        throw error;
      }
    }
    return json({ message: "요청 경로를 확인해 주세요." }, 404);
  }
}
