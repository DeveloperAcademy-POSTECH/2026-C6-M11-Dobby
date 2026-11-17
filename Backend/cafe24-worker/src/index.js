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

function isAllowedMall(mallID, env) {
  if (env.CAFE24_ENV !== "dev") return true;
  const testMallID = env.CAFE24_TEST_MALL_ID?.trim().toLowerCase();
  return Boolean(testMallID) && mallID?.toLowerCase() === testMallID;
}

function devMallNotAllowed() {
  return json({
    error: "dev_mall_not_allowed",
    message: "개발 환경에서는 지정한 테스트 몰만 사용할 수 있습니다.",
  }, 403);
}

async function startOAuth(request, url, env) {
  const deviceToken = bearer(request);
  const mallID = (url.searchParams.get("mall_id") || "").toLowerCase();
  if (!deviceToken || !/^[a-z0-9][a-z0-9_-]{1,39}$/.test(mallID)) return json({ error: "invalid_request" }, 400);
  if (!isAllowedMall(mallID, env)) return devMallNotAllowed();
  const state = crypto.randomUUID();
  const codeVerifier = randomBase64URL(32);
  const codeChallenge = await sha256Base64URL(codeVerifier);
  const deviceKey = await tokenKey(deviceToken);
  const pendingDeviceKey = `pending-device:${deviceKey}`;
  const previousState = await env.CAFE24_TOKENS.get(pendingDeviceKey);

  if (previousState) await env.CAFE24_TOKENS.delete(`pending:${previousState}`);

  await Promise.all([
    env.CAFE24_TOKENS.put(
      `pending:${state}`,
      JSON.stringify({ deviceToken, deviceKey, mallID, codeVerifier }),
      { expirationTtl: 600 },
    ),
    env.CAFE24_TOKENS.put(pendingDeviceKey, state, { expirationTtl: 600 }),
  ]);
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
  if (!isAllowedMall(pending.mallID, env)) return appRedirect(env, "error");
  const pendingDeviceKey = `pending-device:${pending.deviceKey}`;
  const activeState = await env.CAFE24_TOKENS.get(pendingDeviceKey);

  if (!pending.deviceKey || activeState !== state) {
    await env.CAFE24_TOKENS.delete(`pending:${state}`);
    return appRedirect(env, "error");
  }
  const token = await cafe24Token(pending.mallID, env, new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: env.CAFE24_REDIRECT_URI,
    code_verifier: pending.codeVerifier,
  }));
  const latestState = await env.CAFE24_TOKENS.get(pendingDeviceKey);

  if (latestState !== state) {
    await env.CAFE24_TOKENS.delete(`pending:${state}`);
    return appRedirect(env, "error");
  }

  await Promise.all([
    env.CAFE24_TOKENS.put(`connection:${pending.deviceKey}`, JSON.stringify(token)),
    env.CAFE24_TOKENS.delete(`pending:${state}`),
    env.CAFE24_TOKENS.delete(pendingDeviceKey),
  ]);
  return appRedirect(env, "success");
}

async function connection(request, env) {
  const stored = await storedConnection(request, env, false);
  return json(stored && isAllowedMall(stored.mall_id, env)
    ? { connected: true, mallID: stored.mall_id }
    : { connected: false, mallID: null });
}

async function disconnect(request, env) {
  const deviceToken = bearer(request);
  if (!deviceToken) return json({ error: "invalid_request" }, 400);

  const deviceKey = await tokenKey(deviceToken);
  const pendingDeviceKey = `pending-device:${deviceKey}`;
  const pendingState = await env.CAFE24_TOKENS.get(pendingDeviceKey);
  const deletions = [
    env.CAFE24_TOKENS.delete(`connection:${deviceKey}`),
    env.CAFE24_TOKENS.delete(pendingDeviceKey),
  ];

  if (pendingState) deletions.push(env.CAFE24_TOKENS.delete(`pending:${pendingState}`));

  await Promise.all(deletions);
  return json({ disconnected: true });
}

async function createProduct(request, env) {
  let token = await storedConnection(request, env, true);
  const connectionKey = `connection:${await tokenKey(bearer(request))}`;
  if (!isAllowedMall(token.mall_id, env)) return devMallNotAllowed();
  token = await freshToken(token, env, connectionKey);
  const callCafe24 = async (path, method, body) => {
    const result = await cafe24APIWithRefresh(token, env, connectionKey, path, method, body);
    token = result.token;
    return result.value;
  };
  const input = await request.json();
  if (!input.productName || !Number.isInteger(input.price) || input.price < 0) {
    return json({ error: "invalid_product", message: "상품명과 판매가를 확인해 주세요." }, 400);
  }
  const imagesBase64 = Array.isArray(input.imagesBase64)
    ? input.imagesBase64
    : input.imageBase64 ? [input.imageBase64] : [];
  if (!imagesBase64.length || imagesBase64.length > 20
      || imagesBase64.some((image) => typeof image !== "string" || !image)) {
    return json({ error: "invalid_images", message: "상품 사진은 1장 이상 20장 이하로 등록해 주세요." }, 400);
  }
  const category = typeof input.category === "string" ? plainText(input.category).trim() : "";
  if (category.length > 100) {
    return json({ error: "invalid_category", message: "의류 분류를 확인해 주세요." }, 400);
  }
  const categoryNumber = categoryNumberConfiguration(category, env);
  const productDescription = [category && `의류 분류: ${category}`, input.description]
    .filter(value => typeof value === "string" && value.trim())
    .join("\n\n");
  const requestID = typeof input.requestID === "string" ? input.requestID.toLowerCase() : null;
  if (requestID && !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(requestID)) {
    return json({ error: "invalid_request_id", message: "업로드 요청 정보를 확인해 주세요." }, 400);
  }
  const deviceKey = requestID ? await tokenKey(bearer(request)) : null;
  const uploadKey = requestID ? `upload:${token.mall_id}:${deviceKey}:${requestID}` : null;
  const fingerprint = requestID ? await productFingerprint(input, imagesBase64) : null;
  const displayGroup = displayGroupConfiguration(env);
  let progress = uploadKey ? await readUploadProgress(env, uploadKey) : null;
  if (progress?.fingerprint && progress.fingerprint !== fingerprint) {
    return json({ error: "request_conflict", message: "같은 업로드 요청의 상품 정보가 변경되었습니다." }, 409);
  }
  if (progress?.completed && progress.mainDisplayed && progress.inventoryConfigured
      && (!categoryNumber || progress.categoryAssigned)) {
    return json({ productNo: progress.productNo, mallID: token.mall_id });
  }
  progress ||= {
    fingerprint,
    productNo: null,
    representativeAttached: false,
    additionalAttached: false,
    inventoryConfigured: false,
    categoryAssigned: false,
  };

  const [representativeImage, ...additionalImages] = imagesBase64;
  if (additionalImages.some(image => !imageMimeType(image))) {
    return json({
      error: "invalid_additional_images",
      message: "추가 이미지는 JPEG, PNG, GIF 형식으로 등록해 주세요.",
    }, 400);
  }
  if (!progress.additionalAttached && additionalImagesTooLarge(additionalImages)) {
    return json({
      error: "additional_images_too_large",
      message: "추가 사진 용량이 너무 커요. 사진 수나 용량을 줄여 다시 시도해 주세요.",
    }, 413);
  }
  let detailImage;
  if (!progress.representativeAttached) {
    detailImage = toImageDataURL(representativeImage);
    if (!detailImage) {
      return json({
        error: "invalid_representative_image",
        message: "대표 이미지는 JPEG, PNG, GIF 형식으로 등록해 주세요.",
      }, 400);
    }
  }

  if (!progress.productNo && requestID) {
    progress.productNo = await findProductNumber(callCafe24, requestID);
  }
  if (!progress.productNo) {
    const productRequest = {
      product_name: input.productName,
      supply_price: "0",
      price: String(input.price),
      display: "F", selling: "F", has_option: "F",
      summary_description: plainText(productDescription).slice(0, 255),
      description: html(productDescription),
    };
    if (requestID) productRequest.custom_product_code = requestID;
    const created = await callCafe24("/api/v2/admin/products", "POST", {
      shop_no: 1,
      request: productRequest,
    });
    const product = created.product || created.products?.[0];
    if (!product?.product_no) throw new Error("카페24가 생성된 상품번호를 반환하지 않았습니다.");
    progress.productNo = product.product_no;
    await writeUploadProgress(env, uploadKey, progress);
  }
  if (!progress.representativeAttached) {
    await callCafe24(`/api/v2/admin/products/${progress.productNo}/images`, "POST", {
      shop_no: 1,
      request: {
        image_upload_type: "A",
        detail_image: detailImage,
      },
    });
    progress.representativeAttached = true;
    await writeUploadProgress(env, uploadKey, progress);
  }
  if (additionalImages.length > 0 && !progress.additionalAttached) {
    await callCafe24(`/api/v2/admin/products/${progress.productNo}/additionalimages`, "POST", {
      shop_no: 1,
      request: {
        additional_image: additionalImages,
      },
    });
    progress.additionalAttached = true;
    await writeUploadProgress(env, uploadKey, progress);
  }
  if (!progress.inventoryConfigured) {
    const productResource = await callCafe24(
      `/api/v2/admin/products/${progress.productNo}?embed=variants`,
      "GET",
    );
    const product = productResource.product || productResource.products?.[0];
    const variants = Array.isArray(product?.variants) ? product.variants : [];
    if (variants.length !== 1 || !variants[0]?.variant_code) {
      throw new Error("카페24가 단일 상품의 품목코드를 반환하지 않았습니다.");
    }
    await callCafe24(
      `/api/v2/admin/products/${progress.productNo}/variants/${variants[0].variant_code}/inventories`,
      "PUT",
      {
        shop_no: 1,
        request: {
          use_inventory: "T",
          important_inventory: "A",
          inventory_control_type: "A",
          display_soldout: "T",
          quantity: 1,
          safety_inventory: 0,
        },
      },
    );
    progress.inventoryConfigured = true;
    await writeUploadProgress(env, uploadKey, progress);
  }
  if (!progress.published || (categoryNumber && !progress.categoryAssigned)) {
    const productUpdate = { display: "T", selling: "T" };
    if (categoryNumber && !progress.categoryAssigned) {
      productUpdate.add_category_no = [{
        category_no: Number(categoryNumber),
        recommend: "F",
        new: "F",
      }];
    }
    await callCafe24(`/api/v2/admin/products/${progress.productNo}`, "PUT", {
      shop_no: 1,
      request: productUpdate,
    });
    progress.published = true;
    if (categoryNumber) progress.categoryAssigned = true;
    await writeUploadProgress(env, uploadKey, progress);
  }
  if (!progress.mainDisplayed) {
    await callCafe24(`/api/v2/admin/mains/${displayGroup}/products`, "POST", {
      shop_no: 1,
      request: { product_no: progress.productNo },
    });
    progress.mainDisplayed = true;
    await writeUploadProgress(env, uploadKey, progress);
  }
  progress.completed = true;
  await writeUploadProgress(env, uploadKey, progress);
  return json({ productNo: progress.productNo, mallID: token.mall_id }, 201);
}

function additionalImagesTooLarge(images) {
  // Leave room for the JSON envelope and array separators in the 30 MB request budget.
  const maximumBase64Bytes = 30_000_000 - 1024;
  let totalBase64Bytes = 0;
  for (const image of images) {
    const padding = image.endsWith("==") ? 2 : image.endsWith("=") ? 1 : 0;
    const decodedBytes = Math.floor(image.length * 3 / 4) - padding;
    if (decodedBytes > 5_000_000) return true;
    totalBase64Bytes += image.length;
    if (totalBase64Bytes > maximumBase64Bytes) return true;
  }
  return false;
}

function toImageDataURL(base64) {
  const mimeType = imageMimeType(base64);
  return mimeType ? `data:${mimeType};base64,${base64}` : null;
}

function imageMimeType(base64) {
  let header;
  try {
    header = atob(base64.slice(0, 12));
  } catch {
    return null;
  }

  if (header.startsWith("\xFF\xD8\xFF")) return "image/jpeg";
  if (header.startsWith("\x89PNG\r\n\x1A\n")) return "image/png";
  if (header.startsWith("GIF87a") || header.startsWith("GIF89a")) return "image/gif";
  return null;
}

function displayGroupConfiguration(env) {
  const displayGroup = String(env.DEFAULT_DISPLAY_GROUP || "2");
  if (!/^[2-9][0-9]*$/.test(displayGroup)) {
    throw new Error("카페24 메인 진열 그룹은 2 이상의 정수여야 합니다.");
  }
  return displayGroup;
}

function categoryNumberConfiguration(category, env) {
  const categoryNumberByName = {
    "아우터": env.CAFE24_CATEGORY_OUTERWEAR_NO,
    "상의": env.CAFE24_CATEGORY_TOP_NO,
    "하의": env.CAFE24_CATEGORY_BOTTOM_NO,
    "바지": env.CAFE24_CATEGORY_BOTTOM_NO,
  };
  const categoryNumber = categoryNumberByName[category];
  if (!categoryNumber) return null;

  const normalized = String(categoryNumber);
  if (!/^[1-9][0-9]*$/.test(normalized)) {
    throw new Error(`카페24 ${category} 상품 분류 설정을 확인해 주세요.`);
  }
  return normalized;
}

async function findProductNumber(callCafe24, requestID) {
  const query = new URLSearchParams({ custom_product_code: requestID });
  const result = await callCafe24(`/api/v2/admin/products?${query}`, "GET");
  const products = result.products || (result.product ? [result.product] : []);
  return products.find(product => product.custom_product_code?.toLowerCase() === requestID)?.product_no || null;
}

async function productFingerprint(input, imagesBase64) {
  return sha256Base64URL(JSON.stringify({
    productName: input.productName,
    description: input.description || "",
    category: input.category || "",
    price: input.price,
    imagesBase64,
  }));
}

async function readUploadProgress(env, key) {
  const value = key && await env.CAFE24_TOKENS.get(key);
  return value ? JSON.parse(value) : null;
}

async function writeUploadProgress(env, key, progress) {
  if (key) await env.CAFE24_TOKENS.put(key, JSON.stringify(progress), { expirationTtl: 86400 });
}

async function storedConnection(request, env, required) {
  const deviceToken = bearer(request);
  if (!deviceToken) { if (required) throw new Error("앱 인증 정보가 없습니다."); return null; }
  const value = await env.CAFE24_TOKENS.get(`connection:${await tokenKey(deviceToken)}`);
  if (!value && required) throw new Error("먼저 카페24 계정을 연결해 주세요.");
  return value ? JSON.parse(value) : null;
}

async function freshToken(token, env, connectionKey) {
  if (Date.parse(token.expires_at || 0) > Date.now() + 60_000) return token;
  return renewToken(token, env, connectionKey);
}

async function renewToken(token, env, connectionKey) {
  const renewed = await cafe24Token(token.mall_id, env, new URLSearchParams({
    grant_type: "refresh_token", refresh_token: token.refresh_token,
  }));
  await env.CAFE24_TOKENS.put(connectionKey, JSON.stringify(renewed));
  return renewed;
}

async function cafe24APIWithRefresh(token, env, connectionKey, path, method, body) {
  try {
    return { value: await cafe24API(token, env, path, method, body), token };
  } catch (error) {
    if (error.cafe24Status !== 401) throw error;

    const latestText = await env.CAFE24_TOKENS.get(connectionKey);
    const latest = latestText ? JSON.parse(latestText) : null;
    const hasNewerStoredToken = latest?.mall_id === token.mall_id
      && latest.access_token !== token.access_token
      && Date.parse(latest.expires_at || 0) > Date.parse(token.expires_at || 0);
    const recoveredToken = hasNewerStoredToken
      ? latest
      : await renewToken(token, env, connectionKey);

    console.info(JSON.stringify({
      event: "cafe24_access_token_recovered",
      path,
      source: hasNewerStoredToken ? "stored" : "refresh",
      rejectedExpiresAt: token.expires_at || null,
      rejectedExpiresAtHasTimezone: /(?:Z|[+-]\d{2}:\d{2})$/i.test(token.expires_at || ""),
    }));
    return {
      value: await cafe24API(recoveredToken, env, path, method, body),
      token: recoveredToken,
    };
  }
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
    const error = new Error(
      `[${method} ${path}] ${detail || `카페24 상품 등록에 실패했습니다. (HTTP ${response.status})`}`,
    );
    error.cafe24Status = response.status;
    throw error;
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
