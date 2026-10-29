import assert from "node:assert/strict";

// This smoke check can contact only the loopback mock server, never OpenAI.
const port = Number(process.env.DOBBY_LOCAL_PORT || 8787);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("DOBBY_LOCAL_PORT는 1~65535 사이의 포트 번호여야 합니다.");
}
const origin = `http://127.0.0.1:${port}`;
const token = "local-dobby-demo-token";
const sample = {
  photos: [{
    id: "connection-check",
    role: "front",
    // A one-pixel PNG verifies transport and format; it is not a garment fixture.
    imageDataUrl: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII=",
  }],
};

async function call(path, { body, authorization = `Bearer ${token}` } = {}) {
  const response = await fetch(`${origin}${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: body === undefined ? {} : { "Content-Type": "application/json", Authorization: authorization },
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: "error",
    signal: AbortSignal.timeout(5000),
  });
  assert.equal(response.headers.get("X-Dobby-AI-Mode"), "mock", "모의 서버인지 확인할 수 없습니다.");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  return { response, data: await response.json() };
}

try {
  const health = await call("/health");
  assert.equal(health.response.status, 200);
  assert.equal(health.data.mode, "mock");

  const draft = await call("/v1/garments/autofill", { body: sample });
  assert.equal(draft.response.status, 200);
  assert.equal(typeof draft.data.productName, "string");
  assert.equal(draft.data.brand, null);
  assert.ok(draft.data.reviewNotes.some(note => note.includes("모의")));

  const unauthorized = await call("/v1/garments/autofill", { body: sample, authorization: "Bearer invalid-local-token" });
  assert.equal(unauthorized.response.status, 401);
  assert.equal(unauthorized.data.error.code, "unauthorized");

  const invalidPhoto = await call("/v1/garments/autofill", { body: { photos: [] } });
  assert.equal(invalidPhoto.response.status, 400);
  assert.equal(invalidPhoto.data.error.code, "invalid_request");

  console.log("로컬 연결 확인 완료: 상태 200 / 모의 초안 200 / 미인증 401 / 빈 사진 400");
  console.log("OpenAI 호출 없이 고정된 모의 응답을 받았습니다. 실제 사진 분석 결과가 아닙니다.");
  console.log(JSON.stringify(draft.data, null, 2));
} catch (error) {
  console.error(`로컬 연결 확인 실패: ${error.message}`);
  console.error(`먼저 npm run dev:mock으로 ${origin}에서 모의 Worker를 실행해 주세요.`);
  process.exitCode = 1;
}
