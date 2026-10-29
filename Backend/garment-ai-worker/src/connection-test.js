import { createWorker } from "./index.js";

// This entry point is for a separate Cloudflare connection-test Worker.
// It can validate transport and authentication, but can never call OpenAI.
const PUBLIC_LOCAL_TOKEN = "local-dobby-demo-token";
const MOCK_DRAFT = {
  brand: null,
  productNameWithoutBrand: "연결 테스트용 의류",
  description: "이 내용은 Cloudflare 연결 확인용 모의 응답입니다. 사진을 AI로 분석하지 않았습니다.",
  reviewNotes: ["모의 응답입니다. 실제 사진 분석 결과가 아닙니다."],
};
const connectionWorker = createWorker({
  fetchImpl: async () => Response.json({
    status: "completed",
    output: [{
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: JSON.stringify(MOCK_DRAFT) }],
    }],
  }),
});

function withMockHeader(response) {
  const headers = new Headers(response.headers);
  headers.set("X-Dobby-AI-Mode", "mock");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export default {
  async fetch(request, env) {
    const configuredToken = env?.DRAFT_API_TOKEN;
    const response = await connectionWorker.fetch(request, {
      // A public loopback fixture is not a credential for a deployed Worker.
      DRAFT_API_TOKEN: configuredToken === PUBLIC_LOCAL_TOKEN ? undefined : configuredToken,
      // Ignore any actual API key: the injected response above has no network path.
      OPENAI_API_KEY: "connection-test-only-not-a-real-key",
    });
    if (new URL(request.url).pathname === "/health" && request.method === "GET" && response.ok) {
      return withMockHeader(Response.json({ ...await response.json(), mode: "connection-test" }, {
        status: response.status,
        headers: response.headers,
      }));
    }
    return withMockHeader(response);
  },
};
