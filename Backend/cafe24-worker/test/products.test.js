import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

import worker from "../src/index.js";

globalThis.crypto ??= webcrypto;

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
    supplyPrice: 50000,
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
    if (path.endsWith("/products/images")) {
      return Response.json({ images: [{ path: "/uploaded/first.jpg" }] });
    }
    if (path.endsWith("/products")) {
      return Response.json({ product: { product_no: 358 } });
    }
    return Response.json({});
  });

  const response = await worker.fetch(await connectedRequest({
    productName: "빈티지 재킷",
    description: "테스트 상품",
    price: 50000,
    supplyPrice: 50000,
    imagesBase64: ["first-image", "second-image", "third-image"],
  }, environment), environment);

  assert.equal(response.status, 201);
  assert.deepEqual(calls[0].body, { requests: [{ image: "first-image" }] });
  assert.equal(calls[2].body.request.detail_image, "/uploaded/first.jpg");
  assert.deepEqual(calls[3].body.request.additional_image, ["second-image", "third-image"]);
});

test("대표 이미지 경로가 없으면 상품을 생성하지 않는다", async t => {
  const environment = makeEnvironment();
  const paths = [];
  t.mock.method(globalThis, "fetch", async url => {
    paths.push(new URL(url).pathname);
    return Response.json({ images: [] });
  });

  const response = await worker.fetch(await connectedRequest({
    productName: "빈티지 재킷",
    description: "테스트 상품",
    price: 50000,
    supplyPrice: 50000,
    imagesBase64: ["first-image"],
  }, environment), environment);

  assert.equal(response.status, 500);
  assert.deepEqual(paths, ["/api/v2/admin/products/images"]);
});
