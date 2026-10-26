const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "content-type": "application/json; charset=utf-8" },
});

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      const appEndpoint = url.pathname === "/oauth/start"
        || url.pathname === "/connection"
        || url.pathname === "/products";
      if (appEndpoint && !validAppKey(request, env)) {
        return json({ error: "unauthorized", message: "인증되지 않은 앱 요청입니다." }, 401);
      }
      if (request.method === "POST" && url.pathname === "/oauth/start") return await startOAuth(request, url, env);
      if (request.method === "GET" && url.pathname === "/oauth/callback") return await finishOAuth(url, env);
      if (request.method === "GET" && url.pathname === "/connection") return await connection(request, env);
      if (request.method === "DELETE" && url.pathname === "/connection") return await disconnect(request, env);
      if (request.method === "POST" && url.pathname === "/products") return await createProduct(request, env);
      return json({ error: "not_found" }, 404);
    } catch (error) {
      console.error(JSON.stringify({ event: "worker_request_failed", message: error.message || String(error) }));
      return json({ error: "request_failed", message: error.message || "요청 처리에 실패했습니다." }, 500);
    }
  },
};

function validAppKey(request, env) {
  const provided = request.headers.get("X-Dobby-App-Key") || "";
  const expected = env.APP_API_KEY || "";
  if (!provided || !expected || provided.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < provided.length; index += 1) {
    difference |= provided.charCodeAt(index) ^ expected.charCodeAt(index);
  }
  return difference === 0;
}

async function startOAuth(request, url, env) {
  const deviceToken = bearer(request);
  const mallID = (url.searchParams.get("mall_id") || "").toLowerCase();
  if (!deviceToken || !/^[a-z0-9][a-z0-9_-]{1,39}$/.test(mallID)) return json({ error: "invalid_request" }, 400);
  const state = crypto.randomUUID();
  const codeVerifier = randomBase64URL(32);
  const codeChallenge = await sha256Base64URL(codeVerifier);
  await env.CAFE24_TOKENS.put(
    `pending:${state}`,
    JSON.stringify({ deviceToken, mallID, codeVerifier }),
    { expirationTtl: 600 },
  );
  const authorize = new URL(`https://${mallID}.cafe24api.com/api/v2/oauth/authorize`);
  authorize.searchParams.set("response_type", "code");
  authorize.searchParams.set("client_id", env.CAFE24_CLIENT_ID);
  authorize.searchParams.set("state", state);
  authorize.searchParams.set("redirect_uri", env.CAFE24_REDIRECT_URI);
  authorize.searchParams.set("scope", "mall.read_product,mall.write_product");
  authorize.searchParams.set("code_challenge", codeChallenge);
  authorize.searchParams.set("code_challenge_method", "S256");
  return json({ authorizationURL: authorize.toString() });
}

async function finishOAuth(url, env) {
  const state = url.searchParams.get("state"), code = url.searchParams.get("code");
  const pendingText = state && await env.CAFE24_TOKENS.get(`pending:${state}`);
  if (!pendingText || !code) return appRedirect(env, "error");
  const pending = JSON.parse(pendingText);
  const token = await cafe24Token(pending.mallID, env, new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: env.CAFE24_REDIRECT_URI,
    code_verifier: pending.codeVerifier,
  }));
  await env.CAFE24_TOKENS.put(`connection:${await tokenKey(pending.deviceToken)}`, JSON.stringify(token));
  await env.CAFE24_TOKENS.delete(`pending:${state}`);
  return appRedirect(env, "success");
}

async function connection(request, env) {
  const stored = await storedConnection(request, env, false);
  return json(stored ? { connected: true, mallID: stored.mall_id } : { connected: false, mallID: null });
}

async function disconnect(request, env) {
  const deviceToken = bearer(request);
  if (!deviceToken) return json({ error: "invalid_request" }, 400);
  await env.CAFE24_TOKENS.delete(`connection:${await tokenKey(deviceToken)}`);
  return json({ disconnected: true });
}

async function createProduct(request, env) {
  let token = await storedConnection(request, env, true);
  token = await freshToken(token, env, request);
  const input = await request.json();
  if (!input.productName || !Number.isInteger(input.price) || input.price < 0) {
    return json({ error: "invalid_product", message: "상품명과 판매가를 확인해 주세요." }, 400);
  }
  const imagesBase64 = Array.isArray(input.imagesBase64)
    ? input.imagesBase64
    : input.imageBase64 ? [input.imageBase64] : [];
  if (imagesBase64.length > 20 || imagesBase64.some((image) => typeof image !== "string" || !image)) {
    return json({ error: "invalid_images", message: "상품 사진은 최대 20장까지 등록할 수 있습니다." }, 400);
  }
  let imagePath = null;
  if (imagesBase64.length) {
    const uploaded = await cafe24API(token, env, "/api/v2/admin/products/images", "POST", {
      requests: [{ image: imagesBase64[0] }],
    });
    imagePath = uploaded.images?.[0]?.path || uploaded.image?.path || null;
  }
  const created = await cafe24API(token, env, "/api/v2/admin/products", "POST", {
    shop_no: 1,
    request: {
      product_name: input.productName,
      supply_price: String(input.supplyPrice ?? input.price),
      price: String(input.price),
      display: "F", selling: "F", has_option: "F",
      summary_description: plainText(input.description).slice(0, 255),
      description: html(input.description),
    },
  });
  const product = created.product || created.products?.[0];
  if (!product?.product_no) throw new Error("카페24가 생성된 상품번호를 반환하지 않았습니다.");
  if (imagePath) {
    await cafe24API(token, env, `/api/v2/admin/products/${product.product_no}/images`, "POST", {
      shop_no: 1,
      request: {
        image_upload_type: "A",
        detail_image: imagePath,
      },
    });
  }
  if (imagesBase64.length > 1) {
    await cafe24API(token, env, `/api/v2/admin/products/${product.product_no}/additionalimages`, "POST", {
      shop_no: 1,
      request: {
        additional_image: imagesBase64.slice(1),
      },
    });
  }
  return json({ productNo: product.product_no, mallID: token.mall_id }, 201);
}

async function storedConnection(request, env, required) {
  const deviceToken = bearer(request);
  if (!deviceToken) { if (required) throw new Error("앱 인증 정보가 없습니다."); return null; }
  const value = await env.CAFE24_TOKENS.get(`connection:${await tokenKey(deviceToken)}`);
  if (!value && required) throw new Error("먼저 카페24 계정을 연결해 주세요.");
  return value ? JSON.parse(value) : null;
}

async function freshToken(token, env, request) {
  if (Date.parse(token.expires_at || 0) > Date.now() + 60_000) return token;
  const renewed = await cafe24Token(token.mall_id, env, new URLSearchParams({
    grant_type: "refresh_token", refresh_token: token.refresh_token,
  }));
  await env.CAFE24_TOKENS.put(`connection:${await tokenKey(bearer(request))}`, JSON.stringify(renewed));
  return renewed;
}

async function cafe24Token(mallID, env, form) {
  const response = await fetch(`https://${mallID}.cafe24api.com/api/v2/oauth/token`, {
    method: "POST",
    headers: { authorization: `Basic ${btoa(`${env.CAFE24_CLIENT_ID}:${env.CAFE24_CLIENT_SECRET}`)}`,
      "content-type": "application/x-www-form-urlencoded" },
    body: form,
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error_description || "카페24 토큰 발급에 실패했습니다.");
  return body;
}

async function cafe24API(token, env, path, method, body) {
  const response = await fetch(`https://${token.mall_id}.cafe24api.com${path}`, {
    method,
    headers: { authorization: `Bearer ${token.access_token}`, "content-type": "application/json",
      "X-Cafe24-Api-Version": env.CAFE24_API_VERSION },
    body: body ? JSON.stringify(body) : undefined,
  });
  const responseText = await response.text();
  let value;
  try { value = responseText ? JSON.parse(responseText) : {}; }
  catch { value = { raw: responseText }; }
  if (!response.ok) {
    console.error(JSON.stringify({ event: "cafe24_api_error", path, status: response.status, response: value }));
    const detail = value.error?.message
      || value.error_description
      || value.message
      || (typeof value.error === "string" ? value.error : null)
      || responseText;
    throw new Error(`[${method} ${path}] ${detail || `카페24 상품 등록에 실패했습니다. (HTTP ${response.status})`}`);
  }
  return value;
}

function bearer(request) {
  const value = request.headers.get("authorization") || "";
  return value.startsWith("Bearer ") ? value.slice(7) : null;
}

async function tokenKey(value) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

function randomBase64URL(byteLength) {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return bytesToBase64URL(bytes);
}

async function sha256Base64URL(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToBase64URL(new Uint8Array(digest));
}

function bytesToBase64URL(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
}

function appRedirect(env, status) {
  const url = new URL(env.APP_CALLBACK_URI);
  url.searchParams.set("status", status);
  return Response.redirect(url.toString(), 302);
}

function plainText(value = "") { return value.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim(); }
function html(value = "") {
  const escaped = value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  return `<p>${escaped.replaceAll("\n", "<br>")}</p>`;
}
