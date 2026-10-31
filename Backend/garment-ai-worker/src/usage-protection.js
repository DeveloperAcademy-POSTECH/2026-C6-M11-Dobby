const RETRY_AFTER_SECONDS = "60";
const SHARED_USAGE_KEY = "garment-autofill:app";

export class UsageProtectionFailure extends Error {
  constructor(status, code, message, headers = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

function unavailable() {
  return new UsageProtectionFailure(503, "usage_protection_unavailable", "AI 사용량 제한을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.");
}

async function checkLimit(binding, key) {
  let result;
  try {
    result = await binding.limit({ key });
  } catch {
    // Do not expose binding failures, request identifiers, or raw provider errors.
    throw unavailable();
  }
  if (typeof result?.success !== "boolean") throw unavailable();
  if (!result.success) {
    throw new UsageProtectionFailure(429, "rate_limited", "AI 요청이 많습니다. 1분 후 다시 시도해 주세요.", {
      "Retry-After": RETRY_AFTER_SECONDS,
    });
  }
}

export async function enforceAppUsageLimits(env, installationID) {
  const installationLimiter = env?.AI_INSTALLATION_RATE_LIMITER;
  const sharedLimiter = env?.AI_SHARED_RATE_LIMITER;
  // Both bindings are mandatory. Never let a partial deployment call a paid API.
  if (typeof installationLimiter?.limit !== "function" || typeof sharedLimiter?.limit !== "function") {
    throw new UsageProtectionFailure(503, "service_not_configured", "AI 연결 서버 설정이 필요합니다.");
  }
  // Installation IDs are client-generated and replaceable, not authenticated users.
  // The shared key also limits requests that rotate IDs. Cloudflare's native limits
  // are approximate and local to each Cloudflare location, not a global spend cap.
  await checkLimit(installationLimiter, `garment-autofill:installation:${installationID}`);
  await checkLimit(sharedLimiter, SHARED_USAGE_KEY);
}
