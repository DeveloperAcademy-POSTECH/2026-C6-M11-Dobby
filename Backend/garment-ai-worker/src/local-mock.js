import { createWorker } from "./index.js";

// Public fixtures for loopback-only connection testing, never app authentication.
const MOCK_API_TOKEN = "local-dobby-demo-token";
const MOCK_ENV = Object.freeze({
  DRAFT_API_TOKEN: MOCK_API_TOKEN,
  OPENAI_API_KEY: "mock-only-not-a-real-key",
});
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const MOCK_DRAFT = {
  brand: null,
  productNameWithoutBrand: "연결 테스트용 의류",
  description: "이 내용은 로컬 연결 확인용 모의 응답입니다. 사진을 AI로 분석하지 않았습니다.",
  reviewNotes: ["모의 응답입니다. 실제 사진 분석 결과가 아닙니다."],
};

// A separate entry point makes real HTTP requests impossible in this mode.
// Incoming env (including any real .dev.vars) is deliberately never used.
const mockWorker = createWorker({
  fetchImpl: async () => Response.json({
    status: "completed",
    output: [{
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: JSON.stringify({ ...MOCK_DRAFT, identification: null }) }],
    }],
  }),
});

function withMockHeader(response) {
  const headers = new Headers(response.headers);
  headers.delete("X-Dobby-AI-Search-Calls");
  headers.delete("X-Dobby-AI-Search-Attempts");
  headers.delete("X-Dobby-AI-Research-Status");
  headers.set("X-Dobby-AI-Mode", "mock");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (!LOOPBACK_HOSTS.has(url.hostname)) {
      const requestId = crypto.randomUUID();
      return withMockHeader(Response.json({
        error: { code: "local_only", message: "모의 서버는 로컬 연결 테스트 전용입니다." },
        requestId,
      }, {
        status: 503,
        headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "X-Request-Id": requestId },
      }));
    }
    const response = await mockWorker.fetch(request, MOCK_ENV);
    if (url.pathname === "/health" && request.method === "GET" && response.ok) {
      return withMockHeader(Response.json({ ...await response.json(), mode: "mock" }, {
        status: response.status,
        headers: response.headers,
      }));
    }
    return withMockHeader(response);
  },
};
