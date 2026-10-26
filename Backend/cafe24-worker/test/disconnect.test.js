import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

import worker from "../src/index.js";

globalThis.crypto ??= webcrypto;

function makeEnvironment() {
  const values = new Map();

  return {
    APP_API_KEY: "app-key",
    APP_CALLBACK_URI: "dobby-copy://cafe24-connected",
    CAFE24_CLIENT_ID: "client-id",
    CAFE24_CLIENT_SECRET: "client-secret",
    CAFE24_REDIRECT_URI: "https://worker.example/oauth/callback",
    CAFE24_TOKENS: {
      async delete(key) {
        values.delete(key);
      },
      async get(key) {
        return values.get(key) ?? null;
      },
      async put(key, value) {
        values.set(key, value);
      },
    },
    values,
  };
}

async function deviceKey(deviceToken) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(deviceToken));
  return [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

function appRequest(path, deviceToken) {
  return new Request(`https://worker.example${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${deviceToken}`,
      "X-Dobby-App-Key": "app-key",
    },
  });
}

test("연결 해제 시 연결 토큰과 대기 중인 OAuth 요청을 삭제한다", async () => {
  const environment = makeEnvironment();
  const deviceToken = "device-token";
  const key = await deviceKey(deviceToken);
  const state = "pending-state";
  environment.values.set(`connection:${key}`, JSON.stringify({ access_token: "token" }));
  environment.values.set(`pending-device:${key}`, state);
  environment.values.set(`pending:${state}`, JSON.stringify({ deviceKey: key }));

  const response = await worker.fetch(appRequest("/disconnect", deviceToken), environment);

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { disconnected: true });
  assert.equal(environment.values.has(`connection:${key}`), false);
  assert.equal(environment.values.has(`pending-device:${key}`), false);
  assert.equal(environment.values.has(`pending:${state}`), false);
});

test("연결 해제 뒤 도착한 OAuth 콜백은 연결 토큰을 저장하지 않는다", async () => {
  const environment = makeEnvironment();
  const deviceToken = "device-token";
  const startResponse = await worker.fetch(
    appRequest("/oauth/start?mall_id=dobby", deviceToken),
    environment,
  );
  const authorizationURL = new URL((await startResponse.json()).authorizationURL);
  const state = authorizationURL.searchParams.get("state");
  const key = await deviceKey(deviceToken);

  await worker.fetch(appRequest("/disconnect", deviceToken), environment);
  const response = await worker.fetch(
    new Request(`https://worker.example/oauth/callback?state=${state}&code=authorization-code`),
    environment,
  );

  assert.equal(response.status, 302);
  assert.equal(new URL(response.headers.get("location")).searchParams.get("status"), "error");
  assert.equal(environment.values.has(`connection:${key}`), false);
});
