# Dobby 의류 정보 초안 Worker

사진 요청을 받아 제품명·브랜드·설명·판매자 확인 메모를 반환하는 #121 API입니다.

**현재 기본 실행은 로컬 모의 응답입니다.** OpenAI API 키·Cloudflare 로그인·충전 없이 연결 흐름을 확인할 수 있습니다. 사진은 외부로 전송하지 않고, 입력한 사진과 무관한 고정 예시를 반환합니다. 실제 사진 분석 품질을 검증하는 단계는 아닙니다.

## 팀 계정 설정과 현재 상태

2026-10-29 작업 환경에서 Wrangler의 팀 계정 인증과 기존 Dobby Worker 조회를 확인했습니다.

- 팀 계정: `dobbyisvintage@gmail.com`
- Cloudflare 계정 ID: `1bd840ec9780970ad95e2dc88d9d452f`
- `wrangler.toml`과 `wrangler.dev.toml`의 `account_id`에 위 계정을 명시합니다.
- 실제 AI용 대상 이름은 `dobby-openai`, 연결 테스트용 대상 이름은 `dobby-garment-ai-dev`입니다.

**실제 AI용 Worker는 팀 계정에 배포됐고, 이름을 `dobby-garment-ai`에서 `dobby-openai`로 변경했습니다.** 현재 주소는 `https://dobby-openai.dobbyisvintage.workers.dev`입니다. 변경 후 두 Secret 이름과 기존 배포 이력이 유지되고, 새 주소의 `GET /health`가 HTTP 200을 반환함을 확인했습니다. 이 경로는 실행 상태만 확인하고 OpenAI를 호출하지 않습니다. 응답의 `service` 값 `dobby-garment-ai`는 코드 내부 식별자로 유지하며 Cloudflare Worker 이름과는 별개입니다.

개발용 요청 인증 Secret `DRAFT_API_TOKEN`은 등록했고, 로컬 사본은 Git 제외 파일 `.dev.vars.live-check`에 권한 600으로 보관합니다. 사용자가 입력한 `OPENAI_API_KEY`도 Secret 이름 목록에서 등록을 확인했습니다. 키 값을 조회하지 않고 실제 의류 2벌에 각각 1회 요청해, OpenAI가 생성한 초안을 HTTP 200으로 받는 것까지 검증했습니다. 별도 모의 Worker `dobby-garment-ai-dev`는 아직 배포하지 않았습니다. 기존 카페24·Instagram Worker와 iOS 앱 코드는 변경하지 않았습니다.

여기서 **배포**는 이 폴더의 Worker 서버 코드를 Cloudflare에 올려 HTTPS 주소로 API 요청을 받게 만드는 작업입니다. Dobby 앱의 App Store 출시는 별도 작업입니다. 이번 서버 배포는 사용자 승인 후 진행했으며 커밋·푸시·PR 생성은 하지 않았습니다.

개인 계정으로 인증했을 때 작성한 로컬 코드는 그대로 재사용합니다. 이번 작업에서 개인 Cloudflare 계정에 Worker를 배포하거나 Secret을 등록하지 않았으므로 이전할 서버는 없습니다. Wrangler 인증은 팀 계정으로 전환됐지만, 개인 계정의 기존 OAuth 승인을 철회한 것은 아닙니다. 별도 `Dobby-Plane-Test` 초기 작업본 대신 현재 Dobby 저장소의 이 폴더를 작업 기준으로 사용합니다.

## 바로 실행하기

이 폴더(`Backend/garment-ai-worker`)에서 Node.js 22 이상으로 실행합니다.

```sh
npm ci
npm run dev
```

기본 실행 주소는 `http://127.0.0.1:8787`입니다. 같은 폴더의 다른 터미널에서 연결을 확인합니다.

```sh
npm run check:local
```

정상 초안 200, 인증 오류 401, 빈 사진 요청 400을 실제 로컬 HTTP 통신으로 검사합니다. 검사에는 전송 형식을 확인하기 위한 1픽셀 PNG를 사용합니다.

테스트와 두 배포 설정의 번들 확인:

```sh
npm test
npm run dry-run:dev
npm run dry-run
```

두 `dry-run` 명령은 번들만 만들고 배포하거나 OpenAI를 호출하지 않습니다. 다른 포트가 필요하면 `npm run dev:mock -- --port 8788`로 실행하고 `DOBBY_LOCAL_PORT=8788 npm run check:local`로 검사합니다.

## 모의 모드와 실제 모드

| 구분 | 모의 모드 — 기본 실행 | 실제 AI 모드 |
|---|---|---|
| 실행 | `npm run dev` 또는 `npm run dev:mock` | `npm run dev:live` |
| 설정·진입점 | `wrangler.mock.toml`, `src/local-mock.js` | `wrangler.toml`, `src/index.js` |
| AI 응답 | 코드에 고정된 연결 테스트 예시 | `gpt-6-luna` Responses API |
| OpenAI 통신·사용료 | 없음 | 호출 시 사용량에 따른 요금 |
| 인증 | 공개된 로컬 예시 토큰 | 별도로 설정한 개발용 비밀 토큰 |

모의 진입점은 실제 키가 환경에 있어도 사용하지 않습니다. 외부 호스트 요청은 503 `local_only`로 차단하고, 모든 응답에 `X-Dobby-AI-Mode: mock`을 넣습니다. 초안의 설명과 확인 메모에도 모의 응답임을 표시합니다. 모의 설정은 배포용이 아닙니다.

## API 계약

- `GET /health`: 실행 상태만 확인합니다. 실제 OpenAI 연결이나 키 유효성을 검사하지 않습니다.
- `POST /v1/garments/autofill`: 같은 옷 사진 1~5장을 받아 초안 JSON을 반환합니다.
- 요청 헤더: `Content-Type: application/json`, `Authorization: Bearer <토큰>`
- 모의 서버 토큰: `local-dobby-demo-token` — 공개된 연결 확인용 값이며 실제 서비스에 사용하지 않습니다.

```json
{
  "photos": [
    {
      "id": "front-1",
      "role": "front",
      "imageDataUrl": "data:image/jpeg;base64,<사진의 Base64 데이터>"
    }
  ]
}
```

사진 역할은 `front`, `back`, `label`, `detail`, `defect`이고 생략하면 `detail`입니다. JPEG·PNG·WebP 데이터 URL만 받습니다. 사진 한 장 2MiB, 사진 합계 8MiB, JSON 본문 12MiB까지 허용합니다. 앱에서 전송 전에 사진을 축소·압축해야 합니다. 파일 서명 확인은 이미지 전체의 정상 디코딩을 보장하지 않습니다.

모의 서버의 성공 응답:

```json
{
  "productName": "연결 테스트용 의류",
  "brand": null,
  "description": "이 내용은 로컬 연결 확인용 모의 응답입니다. 사진을 AI로 분석하지 않았습니다.",
  "reviewNotes": ["모의 응답입니다. 실제 사진 분석 결과가 아닙니다.", "브랜드 라벨 확인 필요", "하자·오염 상태 실물 확인 필요"]
}
```

실제 모드에서도 위 네 필드를 사용합니다. 확인된 브랜드만 제품명 앞에 붙이고, 브랜드를 확인하지 못하면 `null`로 반환합니다. 설명은 보이는 특징 → 근거 있는 셀링포인트 → 명확한 하자·오염 순서로 작성하도록 지시합니다. 하자가 보이지 않는다는 이유로 ‘하자 없음’을 생성하지 않습니다. 확인 메모는 판매자 검토용으로 상품 설명과 분리합니다.

설명은 보통 2~3개의 짧은 문단으로 작성하고, 문단 사이에는 빈 줄 하나를 둡니다. 근거가 적으면 한 문단도 허용하며, 하자·오염 문단은 명확히 확인될 때만 작성합니다. `description`은 기존 문자열 형식을 유지하고 문단 구분은 실제 줄바꿈 두 번(JSON에서는 `\n\n`)으로 전달합니다. 응답 정리 과정에서도 빈 줄을 보존하므로 앱에서 그대로 표시할 수 있습니다. 제품명·브랜드·확인 메모는 한 줄로 정리합니다. 이 문단 지원 변경은 2026-10-29 팀 `dobby-openai` Worker에 배포했습니다.

가격·실측 사이즈·정품 판정·외부 검색·헤리티지·연식 생성은 이번 범위에서 제외합니다. 모델 지시 준수와 사진 인식 정확도는 실제 사진으로 후속 평가가 필요합니다.

오류는 `{ "error": { "code": "...", "message": "..." }, "requestId": "..." }` 형식입니다.

| 상태 | 의미 |
|---|---|
| 400 / 413 / 415 | 요청 형식·사진·용량 오류 |
| 401 | 개발용 요청 인증 실패 |
| 422 `photo_unusable` | 의류 식별이 어려워 추가 사진 필요 |
| 503 | 서버 미설정·AI 연결 설정 오류·사용량 제한 |
| 502 | AI 응답 오류·연결 실패 |
| 504 | AI 응답 30초 초과 |

잘못된 요청은 AI 호출 전에 차단합니다. 자동 재시도는 없고, 키·사진·모델 원문·원본 AI 오류를 로그에 남기지 않습니다. 응답은 `no-store`입니다.

## 배포된 AI Worker에 OpenAI 키 입력하기

Cloudflare 팀 계정에서 `dobby-openai` → **Settings → Runtime variables and secrets**로 이동합니다. 현재 키는 등록돼 있으며, 아래는 추후 교체할 때의 입력 기준입니다.

- Type: **Secret**
- Variable name: **`OPENAI_API_KEY`**
- Value: 사용자가 OpenAI 팀 프로젝트에서 발급한 API 키를 직접 입력합니다.

Cloudflare 화면의 저장·배포 동작으로 반영합니다. `DRAFT_API_TOKEN`은 이미 등록돼 있으므로 새로 입력할 필요가 없습니다. OpenAI 키는 채팅·Git·Swift 코드·이 README에 넣지 않습니다. 키 등록 자체는 사진 분석 요청을 보내지 않습니다.

키 등록 후 사용자 승인으로 실제 사진 요청 2회를 실행했습니다. 아래의 `check:cloud` 명령은 별도 모의 Worker용이며 이 실제 AI 서버를 검사하는 명령이 아닙니다. 추가 유료 사진 분석은 사용자가 요청한 범위에서 진행합니다.

## 검증 결과

2026-10-29 기준으로 자동 테스트 104개와 실제 AI용 설정의 배포 전 번들 확인(`npm run dry-run`)이 통과했습니다. 문단 유지·공백 정리·빈 설명·길이 제한·제어문자 검증을 포함합니다. 자동 테스트는 실제 OpenAI를 호출하지 않습니다.

문단 지원 배포 버전은 `9cb910e6-816f-4af3-b67b-aa74cf640496`이며 트래픽 100% 적용을 확인했습니다. 배포 후 `GET /health` HTTP 200과 `OPENAI_API_KEY`·`DRAFT_API_TOKEN` Secret 이름 유지를 확인했고, 이 배포 검증에서 추가 OpenAI 호출은 하지 않았습니다.

| 실제 사진 테스트 | 사진 수 | 결과 | 전체 요청 시간 |
|---|---|---|---|
| 그래픽 반팔 티셔츠 | 5장 | HTTP 200, 제품명·브랜드·설명·확인 메모 생성 | 약 40.5초 |
| 디스트레스 데님 팬츠 | 4장 | HTTP 200, 제품명·브랜드·설명·확인 메모 생성 | 약 11.7초 |

위 시간은 사진 업로드를 포함하며 순수 모델 처리 시간이 아닙니다. HEIC 원본은 JPEG 사본으로 변환해 전송했습니다. 두 실제 테스트는 문단 구분 수정 전 결과입니다. 문단 보존 처리는 자동 테스트로 확인했으며, 수정된 프롬프트로 실제 문단이 생성되는지는 추가 유료 호출로 재검증하지 않았습니다.

브랜드·주요 디자인은 인식했지만, 목둘레 변색 의심 누락, 혼합 문자 표기, 핏 추정, 디스트레스와 추가 손상 구분은 후속 평가 항목입니다. 두 건의 성공이 모든 의류의 생성 품질을 보장하지는 않습니다. Worker는 토큰 사용량을 반환하지 않으며 실제 사용량은 OpenAI 프로젝트 Usage에서 확인합니다.

## 별도 Cloudflare 모의 연결 테스트용 배포 준비

별도 `wrangler.dev.toml`과 `src/connection-test.js`는 실제 Cloudflare HTTPS 연결 확인용입니다. 배포 대상 이름은 `dobby-garment-ai-dev`이고, 현재 구성 준비 단계이며 아직 배포하지 않았습니다.

팀 계정에서 사용할 예정 주소는 `https://dobby-garment-ai-dev.dobbyisvintage.workers.dev`입니다. **아직 배포되지 않은 예정 주소이며, 현재 사용할 수 있는 API 주소가 아닙니다.**

이 진입점은 실제 OpenAI 키가 환경에 있어도 무시하고 고정된 모의 응답을 반환합니다. 공개 상태 확인 경로는 `mode: "connection-test"`와 `X-Dobby-AI-Mode: mock`으로 구분합니다. 사진 초안 요청에는 별도로 등록한 `DRAFT_API_TOKEN` 비밀값이 필요합니다. 공개된 로컬 토큰을 사용하지 않습니다.

이 별도 모의 Worker는 아직 배포하지 않았으므로 `check:cloud`를 지금 실행하지 않습니다. 로컬 모의 실행·테스트와 두 `dry-run` 명령은 계속 사용할 수 있습니다.

실제 배포는 대상과 동작을 확인하고 별도 승인받은 뒤 진행합니다. 배포 시 개발용 토큰을 무작위로 만들고, 로컬의 Git 제외 파일 `.dev.vars.connection-test`에 권한 600으로 보관한 뒤 Worker의 비밀값으로 등록합니다. OpenAI API 키 등록은 이 테스트에 필요하지 않습니다.

**추후 배포와 토큰 등록이 완료되고 실제 주소를 확인한 이후에만** 다음 명령으로 상태·사진 전송·인증·입력 검증을 확인합니다.

```sh
npm run check:cloud -- https://dobby-garment-ai-dev.dobbyisvintage.workers.dev
```

이 스크립트는 위 팀 계정의 정확한 HTTPS 주소만 허용하고, 모의 모드 확인 후에만 개발용 토큰을 전송하며 리다이렉트는 따르지 않습니다. 다른 계정이나 기존 카페24·Instagram 서버 주소로 요청하지 않습니다. 정상 요청도 고정된 연결 확인용 예시를 반환하므로 사진 분석 품질을 검증하지는 않습니다.

## 로컬에서 실제 AI 호출을 개발할 때

배포된 Worker의 Secret 설정과 별도로, 로컬에서 실제 AI를 호출하려면 `.dev.vars.example`을 `.dev.vars`로 복사한 뒤 **사용자가 직접** 다음 값을 입력합니다. 현재 이 로컬 키 파일은 만들지 않았습니다. 이 파일은 Git에서 제외되며 키를 채팅에 붙여넣을 필요가 없습니다.

- `OPENAI_API_KEY`: OpenAI 프로젝트 API 키
- `DRAFT_API_TOKEN`: 별도로 만든 긴 무작위 개발용 인증 토큰

`npm run dev:live`는 Worker를 로컬에서 실행하지만 실제 API 요청을 받으면 OpenAI를 호출하므로 사용료가 발생할 수 있습니다. 키 파일 등록만으로 호출하지는 않습니다. 추가 코드 배포는 코드·테스트 결과 확인 후 별도 승인 범위에서 진행합니다.

이 토큰은 개발자 연결 테스트용입니다. iOS 앱에 공통 토큰을 포함하지 않고, 사용자 배포 전에 요청 인증과 사용량 제한을 구현해야 합니다. 앱 화면 연결은 #122, 실제 연결·배포 준비는 #123 범위입니다.

실제 사진 요청의 Cloudflare CPU 한도 충족 여부는 후속 측정이 필요합니다. OpenAI에는 `store: false`로 요청하지만 이는 모든 데이터 보관 정책을 해제한다는 뜻은 아닙니다.

공식 문서: [Cloudflare 로컬 실행](https://developers.cloudflare.com/workers/local-development/), [비밀값 설정](https://developers.cloudflare.com/workers/configuration/secrets/), [OpenAI Docs — Luna](https://developers.openai.com/api/docs/models/gpt-6-luna), [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [사진 입력](https://developers.openai.com/api/docs/guides/images-vision).
