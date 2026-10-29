import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const EXPECTED_ORIGIN = "https://dobby-garment-ai-dev.dobbyisvintage.workers.dev";

const sample = {
  photos: [{
    id: "cloud-connection-check",
    role: "front",
    // Transport-only fixture; no real garment image or AI request is involved.
    imageDataUrl: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=",
  }],
};

async function request(origin, path, { body, token } = {}) {
  const response = await fetch(`${origin}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: body === undefined ? {} : {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: "error",
    signal: AbortSignal.timeout(10000),
  });
  assert.equal(response.headers.get("X-Dobby-AI-Mode"), "mock", "테스트용 모의 Worker가 아닙니다.");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  return { response, data: await response.json() };
}

try {
  const requestedURL = process.argv[2];
  if (requestedURL !== EXPECTED_ORIGIN && requestedURL !== `${EXPECTED_ORIGIN}/`) {
    throw new Error(`팀 계정의 AI 테스트 주소만 지정해 주세요: ${EXPECTED_ORIGIN}`);
  }
  const url = new URL(requestedURL);

  // Verify the endpoint's mode before reading or transmitting the private test token.
  const health = await request(url.origin, "/health");
  assert.equal(health.response.status, 200);
  assert.equal(health.data.mode, "connection-test");

  let values;
  try { values = await readFile(new URL("../.dev.vars.connection-test", import.meta.url), "utf8"); }
  catch { throw new Error("로컬 .dev.vars.connection-test에 개발용 인증 토큰 등록이 필요합니다."); }
  const token = values.match(/^DRAFT_API_TOKEN=([A-Za-z0-9_-]{32,})\r?$/m)?.[1];
  if (!token) throw new Error("개발용 인증 토큰의 형식을 확인해 주세요.");

  const draft = await request(url.origin, "/v1/garments/autofill", { body: sample, token });
  assert.equal(draft.response.status, 200);
  assert.equal(draft.data.brand, null);
  assert.ok(draft.data.reviewNotes.some(note => note.includes("모의")));

  const unauthorized = await request(url.origin, "/v1/garments/autofill", { body: sample, token: "invalid-test-token" });
  assert.equal(unauthorized.response.status, 401);
  assert.equal(unauthorized.data.error.code, "unauthorized");

  const invalidPhoto = await request(url.origin, "/v1/garments/autofill", { body: { photos: [] }, token });
  assert.equal(invalidPhoto.response.status, 400);
  assert.equal(invalidPhoto.data.error.code, "invalid_request");

  console.log("Cloudflare 연결 확인 완료: 상태 200 / 모의 초안 200 / 미인증 401 / 빈 사진 400");
  console.log("고정된 테스트 응답을 확인했습니다. OpenAI를 호출하거나 사진을 분석하지 않았습니다.");
} catch (error) {
  console.error(`Cloudflare 연결 확인 실패: ${error.message}`);
  console.error(`사용법: npm run check:cloud -- ${EXPECTED_ORIGIN}`);
  process.exitCode = 1;
}
