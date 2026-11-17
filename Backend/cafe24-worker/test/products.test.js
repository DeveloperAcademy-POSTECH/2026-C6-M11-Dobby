import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

import worker from "../src/index.js";

globalThis.crypto ??= webcrypto;

const pngImage = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7ZkAAAAASUVORK5CYII=";
const jpegHeader = "/9j/4AAQSkZJRg==";

function makeEnvironment() {
  const values = new Map();
  return {
    APP_API_KEY: "app-key",
    CAFE24_API_VERSION: "2026-09-01",
    CAFE24_CLIENT_ID: "client-id",
    CAFE24_CLIENT_SECRET: "client-secret",
    CAFE24_TOKENS: {
      async get(key) { return values.get(key) ?? null; },
      async put(key, value) { values.set(key, value); },
    },
    values,
  };
}

async function connectedRequest(body, environment) {
  const deviceToken = "device-token";
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(deviceToken));
  const deviceKey = [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  environment.values.set(`connection:${deviceKey}`, JSON.stringify({
    access_token: "access-token",
    expires_at: "2999-01-01T00:00:00+00:00",
    mall_id: "dobbyisvintage",
  }));
  return new Request("https://worker.example/products", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${deviceToken}`,
      "Content-Type": "application/json",
      "X-Dobby-App-Key": "app-key",
    },
    body: JSON.stringify(body),
  });
}

test("상품 사진이 없으면 카페24 API를 호출하지 않는다", async t => {
  const environment = makeEnvironment();
  t.mock.method(globalThis, "fetch", async () => {
    assert.fail("카페24 API를 호출하면 안 됩니다.");
  });

  const response = await worker.fetch(await connectedRequest({
    productName: "빈티지 재킷",
    description: "테스트 상품",
    price: 50000,
    imagesBase64: [],
  }, environment), environment);

  assert.equal(response.status, 400);
});

test("첫 사진을 대표 이미지로 연결하고 나머지만 추가 이미지로 등록한다", async t => {
  const environment = makeEnvironment();
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, options) => {
    const path = new URL(url).pathname;
    const body = options.body ? JSON.parse(options.body) : null;
    calls.push({ path, body });
    if (path === "/api/v2/admin/products") {
      return Response.json({ product: { product_no: 358 } });
    }
    if (path === "/api/v2/admin/products/358" && options.method === "GET") {
      return Response.json({ product: { variants: [{ variant_code: "P00000GR000A" }] } });
    }
    return Response.json({});
  });

  const response = await worker.fetch(await connectedRequest({
    productName: "빈티지 재킷",
    description: "테스트 상품",
    category: "아우터",
    price: 50000,
    imagesBase64: [pngImage, jpegHeader],
  }, environment), environment);

  assert.equal(response.status, 201);
  assert.equal(calls[0].path, "/api/v2/admin/products");
  assert.equal(calls[0].body.request.description, "<p>의류 분류: 아우터<br><br>테스트 상품</p>");
  assert.equal(calls[1].path, "/api/v2/admin/products/358/images");
  assert.deepEqual(calls[1].body.request, {
    image_upload_type: "A",
    detail_image: `data:image/png;base64,${pngImage}`,
  });
  assert.equal(calls[2].path, "/api/v2/admin/products/358/additionalimages");
  assert.deepEqual(calls[2].body.request.additional_image, [jpegHeader]);
});

test("대표 이미지의 파일 형식을 인식할 수 없으면 상품을 생성하지 않는다", async t => {
  const environment = makeEnvironment();
  const paths = [];
  t.mock.method(globalThis, "fetch", async url => {
    paths.push(new URL(url).pathname);
    return Response.json({});
  });

  const response = await worker.fetch(await connectedRequest({
    productName: "빈티지 재킷",
    description: "테스트 상품",
    price: 50000,
    imagesBase64: ["bm90LWFuLWltYWdl"],
  }, environment), environment);

  assert.equal(response.status, 400);
  assert.deepEqual(paths, []);
  assert.equal((await response.json()).error, "invalid_representative_image");
});

test("이미지 단계 실패 후 같은 요청을 재시도해도 상품을 중복 생성하지 않는다", async t => {
  const environment = makeEnvironment();
  let productCreates = 0;
  let representativeAttaches = 0;
  let additionalAttaches = 0;
  t.mock.method(globalThis, "fetch", async (url, options) => {
    const parsedURL = new URL(url);
    const path = parsedURL.pathname;
    if (path === "/api/v2/admin/products" && options.method === "GET") {
      return Response.json({ products: [] });
    }
    if (path === "/api/v2/admin/products" && options.method === "POST") {
      productCreates += 1;
      const body = JSON.parse(options.body);
      assert.equal(body.request.custom_product_code, "550e8400-e29b-41d4-a716-446655440000");
      return Response.json({ product: { product_no: 358 } });
    }
    if (path === "/api/v2/admin/products/358/images") {
      representativeAttaches += 1;
      return Response.json({});
    }
    if (path.endsWith("/additionalimages")) {
      additionalAttaches += 1;
      if (additionalAttaches === 1) {
        return Response.json({ message: "temporary failure" }, { status: 500 });
      }
      return Response.json({});
    }
    if (path === "/api/v2/admin/products/358" && options.method === "GET") {
      return Response.json({ product: { variants: [{ variant_code: "P00000GR000A" }] } });
    }
    if (options.method === "PUT" || path.endsWith("/mains/2/products")) {
      return Response.json({});
    }
    assert.fail(`예상하지 못한 카페24 API 호출: ${path}`);
  });

  const body = {
    requestID: "550E8400-E29B-41D4-A716-446655440000",
    productName: "빈티지 재킷",
    description: "테스트 상품",
    price: 50000,
    imagesBase64: [pngImage, jpegHeader],
  };
  const firstResponse = await worker.fetch(await connectedRequest(body, environment), environment);
  const retryResponse = await worker.fetch(await connectedRequest(body, environment), environment);

  assert.equal(firstResponse.status, 500);
  assert.equal(retryResponse.status, 201);
  assert.equal(productCreates, 1);
  assert.equal(representativeAttaches, 1);
  assert.equal(additionalAttaches, 2);
  assert.equal((await retryResponse.json()).productNo, 358);
});

test("연결된 몰은 이미지 등록 완료 후 상품을 공개하고 메인에 진열한다", async t => {
  const environment = makeEnvironment();
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, options) => {
    const path = new URL(url).pathname;
    const body = options.body ? JSON.parse(options.body) : null;
    calls.push({ path, method: options.method, body });
    if (path === "/api/v2/admin/products" && options.method === "POST") {
      return Response.json({ product: { product_no: 358 } });
    }
    if (path === "/api/v2/admin/products/358" && options.method === "GET") {
      return Response.json({ product: { variants: [{ variant_code: "P00000GR000A" }] } });
    }
    return Response.json({});
  });

  const response = await worker.fetch(await connectedRequest({
    productName: "빈티지 재킷",
    description: "테스트 상품",
    price: 50000,
    imagesBase64: [jpegHeader],
  }, environment), environment);

  assert.equal(response.status, 201);
  assert.deepEqual(calls.map(call => [call.method, call.path]), [
    ["POST", "/api/v2/admin/products"],
    ["POST", "/api/v2/admin/products/358/images"],
    ["GET", "/api/v2/admin/products/358"],
    ["PUT", "/api/v2/admin/products/358/variants/P00000GR000A/inventories"],
    ["PUT", "/api/v2/admin/products/358"],
    ["POST", "/api/v2/admin/mains/2/products"],
  ]);
  assert.equal(calls[1].body.request.detail_image, `data:image/jpeg;base64,${jpegHeader}`);
  assert.deepEqual(calls[3].body.request, {
    use_inventory: "T",
    important_inventory: "A",
    inventory_control_type: "A",
    display_soldout: "T",
    quantity: 1,
    safety_inventory: 0,
  });
  assert.deepEqual(calls[4].body.request, { display: "T", selling: "T" });
  assert.deepEqual(calls[5].body.request, { product_no: [358] });
});
