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

개발용 요청 인증 Secret `DRAFT_API_TOKEN`은 등록했고, 로컬 사본은 Git 제외 파일 `.dev.vars.live-check`에 권한 600으로 보관합니다. 사용자가 입력한 `OPENAI_API_KEY`도 Secret 이름 목록에서 등록을 확인했습니다. 키 값을 조회하지 않고 실제 의류 2벌에 각각 1회 요청해, OpenAI가 생성한 초안을 HTTP 200으로 받는 것까지 검증했습니다. 별도 모의 Worker `dobby-garment-ai-dev`는 아직 배포하지 않았습니다. 이는 당시 API 구현 검증 기록입니다. 아래 공통 인증 수정은 iOS 클라이언트도 변경하며 기존 카페24·Instagram Worker 코드는 변경하지 않습니다.

여기서 **배포**는 이 폴더의 Worker 서버 코드를 Cloudflare에 올려 HTTPS 주소로 API 요청을 받게 만드는 작업입니다. Dobby 앱의 App Store 출시는 별도 작업입니다. 이번 서버 배포는 사용자 승인 후 진행했으며 커밋·푸시·PR 생성은 하지 않았습니다.

개인 계정으로 인증했을 때 작성한 로컬 코드는 그대로 재사용합니다. 이번 작업에서 개인 Cloudflare 계정에 Worker를 배포하거나 Secret을 등록하지 않았으므로 이전할 서버는 없습니다. Wrangler 인증은 팀 계정으로 전환됐지만, 개인 계정의 기존 OAuth 승인을 철회한 것은 아닙니다. 별도 `Dobby-Plane-Test` 초기 작업본 대신 현재 Dobby 저장소의 이 폴더를 작업 기준으로 사용합니다.

## 공통 앱 인증

이번 수정은 기존 `dobby-openai`를 그대로 사용하면서 앱 공통 인증을 추가합니다. **2026-10-31 사용자 승인 후 수정 코드와 두 호출 제한 바인딩을 배포했습니다.** 공통 인증 배포 버전은 `c2b63e32-62bb-4631-b01b-a5858c0dca51`이며 트래픽 100% 적용을 확인했습니다. 위의 2026-10-29 기록은 기존 개발 토큰 방식의 기록입니다.

| 요청 방식 | 필요한 설정 | 처리 |
|---|---|---|
| 기본 앱 공통 인증 | Secret `DOBBY_APP_API_KEY`, 두 Rate Limiting 바인딩 | `X-Dobby-App-Key` 확인 + 설치별 64자리 소문자 hex Bearer 검사 + 호출 횟수 제한 |
| 기존 개발 연결 | Secret `DRAFT_API_TOKEN` | 앱 키 헤더가 없는 요청에서 기존 Bearer 인증 유지 |

새 Secret **`DOBBY_APP_API_KEY`는 앱의 기존 `DOBBY_INSTAGRAM_APP_API_KEY`와 같은 값**으로 등록합니다. Instagram Worker가 검증하는 앱 접근 키이며, OpenAI 키나 Cafe24 설정의 동명 키를 복사하는 것이 아닙니다. Worker 사이에 Secret은 자동 공유되지 않습니다. 기존 `OPENAI_API_KEY`와 `DRAFT_API_TOKEN`은 유지합니다.

앱은 `InstagramAppAPIKey` 설정과 기존 Instagram Keychain 설치별 인증값을 재사용합니다. 인증값이 없으면 최초 요청 때 자동 생성하므로 일반 Dobby scheme으로 빌드할 수 있습니다. 팀원 Mac에도 기존 앱 비밀 설정은 있어야 하며, AI 전용 scheme이나 기기별 개발 토큰 주입은 필요하지 않습니다. Instagram OAuth 로그인은 AI 사용의 전제조건이 아닙니다.

앱 키 헤더가 있으면 공통 인증만 검사합니다. 잘못된 앱 키가 있는 요청은 유효한 개발 토큰이 있어도 거절합니다. 공통 인증용 바인딩이 빠졌거나 제한 검사가 실패하면 OpenAI를 호출하지 않습니다.

`wrangler.toml`은 `AI_INSTALLATION_RATE_LIMITER`(설치별 60초에 5회)와 `AI_SHARED_RATE_LIMITER`(공통 60초에 30회)를 선언합니다. 제한 초과는 429 `rate_limited`, `Retry-After: 60`으로 반환합니다. 이는 [Cloudflare 공식 Rate Limiting 문서](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/) 기준 위치별 근사 제한이며 전 세계 합산 과금 상한이 아닙니다. 배포 전 팀 계정 Worker 4개의 설정을 조회해 namespace ID `1211221`·`1211222`가 다른 Worker의 제한 설정과 겹치지 않음을 확인했습니다. 앱 공통 키와 자가 생성 설치 식별자는 사용자 로그인이나 앱 진위 증명을 대체하지 않습니다. 신뢰된 기존 개발 토큰은 호환성을 위해 이 새 제한 경로를 사용하지 않습니다.

사용자가 새 Secret을 등록한 뒤 같은 Worker에 수정 코드·바인딩 배포를 완료했습니다. 기존 `DOBBY_APP_API_KEY`·`OPENAI_API_KEY`·`DRAFT_API_TOKEN` Secret 이름 유지, `GET /health` 200, 정상 공통 인증 + 빈 사진 요청 400 `invalid_request`, 잘못된 공통 인증 401 `unauthorized`를 확인했습니다. 빈 사진 요청은 OpenAI 호출 전에 종료되며 실제 사진·AI 생성 요청을 보내지 않았습니다. 기존 Instagram Worker를 변경하거나 커밋·푸시·PR을 수행하지 않았습니다. **앱은 이 인증 수정 코드로 다시 빌드해야 합니다.**

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
| 인증 | 공개된 로컬 예시 토큰 | 공통 앱 인증 또는 기존 개발용 비밀 토큰 |

모의 진입점은 실제 키가 환경에 있어도 사용하지 않습니다. 외부 호스트 요청은 503 `local_only`로 차단하고, 모든 응답에 `X-Dobby-AI-Mode: mock`을 넣습니다. 초안의 설명과 확인 메모에도 모의 응답임을 표시합니다. 모의 설정은 배포용이 아닙니다.

## API 계약

- `GET /health`: 실행 상태만 확인합니다. 실제 OpenAI 연결이나 키 유효성을 검사하지 않습니다.
- `POST /v1/garments/autofill`: 같은 옷 사진 1~5장을 받아 초안 JSON을 반환합니다.
- `POST /v1/garments/landmarks`: 아우터 한 벌의 고정 촬영 사진에서 11점과 뒷목 봉제선 중앙 관측을 반환합니다. 아래의 새 측정점 계약을 따릅니다.
- `POST /v3/garments/landmarks`: 앞면 총장 전용 계약입니다. 11점과 앞목 시작점 하나를 반환합니다.
- `POST /v3/garments/landmark-refinement`: 같은 앞면 전용 계약을 사용하는 부위 확대 경로입니다.
- `POST /v2/garments/landmarks`: 이전 앞목·뒷목 보조 관측을 분리한 계약입니다. 2026-11-02 01:43(KST) 원격 배포를 완료했습니다. 아래 v2 절을 참고하세요.
- `POST /v2/garments/landmark-refinement`: 아우터 A/B/C 사진 비교의 C 전용 확대 관측 경로입니다. 기존 v1/v2 촬영 경로와 별개입니다.
- 요청 헤더: `Content-Type: application/json`, `Authorization: Bearer <토큰>`. 공통 앱 인증은 `X-Dobby-App-Key`도 필요합니다.
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
| 401 | 요청 인증 실패 |
| 429 | 공통 앱 호출 횟수 제한 초과 (`Retry-After: 60`) |
| 422 `photo_unusable` | 의류 식별이 어려워 추가 사진 필요 |
| 503 | 서버 미설정·AI 연결 설정 오류·사용량 제한 |
| 502 | AI 응답 오류·연결 실패 |
| 504 | AI 응답 30초 초과 |

잘못된 요청은 AI 호출 전에 차단합니다. 자동 재시도는 없고, 키·사진·모델 원문·원본 AI 오류를 로그에 남기지 않습니다. 응답은 `no-store`입니다.

## 현재 앱: 앞면 전용 총장 v3

2026-11-02(KST) `6f03b6f9-db31-40e4-947d-0bbc9193a85d`로 배포했습니다. Swift 코어 714개, Worker 236개, iOS 저장·클라이언트 49개와 비교 화면 1개 테스트가 통과했습니다. 배포 후 health 200과 두 v3 경로의 무인증 POST 401을 확인했습니다. 실제 Luna 사진 요청은 이 배포 검증에 포함하지 않았습니다.

새 앱은 `/v3/garments/landmarks`와 `/v3/garments/landmark-refinement`를 사용합니다. 요청 본문·인증·제한·11개 점 정의는 유지합니다. 응답은 `outerwear-landmarks-v3` / `luna-outerwear11-front-length-v3`이며, `frontNeckSeamCenter`만 총장 보조점으로 요구하고 `backNeckSeamCenter`는 스키마에서 제외합니다. 앞목 몸판 연결/마감 봉제선 중앙부터 앞면 밑단 중앙까지가 기본 총장입니다. 후드·칼라 높이, 안쪽에 보이는 뒷목, 목옆 평균으로 대체하지 않습니다. 실제 앞목이 가려지거나 빈 공간이면 null을 유지합니다.

확대 경로의 `refinementVersion`은 `outerwear-front-refinement-v3`이며 `localResponse`는 v3입니다. `upper` 사진에서 목옆·어깨와 앞목 보조점만 요청합니다. 앱은 앞목 좌표를 `top_length_start`에 연결해 `top.totalLength` / `totalLength`로 표시·저장합니다. 앞뒤를 판별할 수 없거나 실제 뒷면이면 앞목을 만들지 않으며 뒷목으로 총장을 대체하지 않습니다. 기존 v1/v2 경로·응답과 저장 기록의 의미는 유지합니다.

## 아우터 측정점 v1 API — 원격 배포 완료

### 사진 비교용 확대 관측

2026-11-02(KST) Sweater를 일반 측정점·확대 관측 API의 허용 대상에 추가하고 `76b46775-8690-4b68-b544-136a2774c8c9`로 배포했습니다. 앱의 실측·사진 비교도 같은 7종을 대상으로 사용합니다. 분류 테스트 23개·Worker 테스트 233개·iOS 비교 화면 테스트 1개가 통과했고, 배포 후 health 200 및 두 v2 경로의 무인증 요청 401을 확인했습니다. 이 검증에서는 실제 Luna 사진 요청을 보내지 않았습니다.

2026-11-02 02:23(KST) `dobby-openai` 버전 `3c1f1882-777b-46f9-83c0-b4edfc1f70a5`로 배포했습니다. health 200, 확대 경로 OPTIONS 405/Allow POST, 무인증 POST 401을 확인했습니다. 이 배포 검사는 실제 사진을 Luna에 전송하지 않았습니다.

`/v2/garments/landmark-refinement` 요청은 `{requestId, category, image, regions}`입니다. `image`는 옷 전체 참고 이미지이며 기존 `{imageDataUrl,width,height}` 형식입니다. `regions`는 `{id,image}` 5개를 정확히 포함합니다: `upper`(목옆/어깨/앞뒤 총장 시작), `armpits`(겨드랑이), `leftCuff`, `rightCuff`, `hem`(밑단 3점). 중복·누락·알 수 없는 부위·추가 필드는 거절합니다. 각 사진 2MiB, 6장 합계 8MiB, 본문 12MiB 한도입니다.

한 번의 Luna 요청에서 부위별 **크롭 기준 정규화 좌표**를 반환합니다. 응답은 `{refinementVersion:"outerwear-local-refinement-v1", localResponse:<v2 관측>}`로 감싸 일반 전체 이미지 응답과 구분합니다. 클라이언트가 저장한 각 실제 크롭 범위로 역변환하며 서버는 전체 사진 좌표를 추정하지 않습니다. 같은 모델·추론/출력 한도·물리적 측정점·null 규칙을 유지합니다. 실제 위치 정확도와 총장 성공률은 실제 사진 비교로 따로 검증해야 합니다.

기존 인증·사용량 제한·30초 upstream 제한·로그 비저장·무재시도 정책을 재사용합니다. v1/v2의 기존 측정점·총장 정의와 응답 스키마를 유지합니다. 모의 판매글 서버에는 이 경로가 없고 `npm test`의 HTTP 대역으로 계약을 검증합니다.

`POST /v1/garments/landmarks`는 기존 실제 AI 진입점 `src/index.js`에 추가했습니다. 기존 `/autofill`의 입출력은 유지합니다. **2026-11-02(KST) 사용자가 `dobby-openai`에 배포를 완료했고, 배포 성공 로그의 버전은 `f2c7131b-e490-497b-88bd-a0483fcd7464`입니다.** 대상 주소는 [dobby-openai Worker](https://dobby-openai.dobbyisvintage.workers.dev)입니다. 기본 `npm run dev`의 판매글 모의 진입점에는 이 새 경로가 없으며, 자동 테스트는 `createWorker`에 주입한 HTTP 대역으로 새 경로를 실행합니다.

배포 직후 원격 확인 범위는 다음과 같습니다. 이 초기 검사에서는 실제 사진이나 유효한 인증을 포함한 AI 생성 요청은 보내지 않았습니다.

| 확인 요청 | 결과 | 확인 범위 |
|---|---|---|
| `GET /health` | 200 | Worker 실행 상태 |
| `OPTIONS /v1/garments/landmarks` | 405, `Allow: POST` | 새 경로가 인식됨. 이전 404 해소 |
| 무인증 빈 JSON `POST /v1/garments/landmarks` | 401, `unauthorized` | 인증 없는 요청 거절 |

읽기 전용 Secret 목록 조회로 `DOBBY_APP_API_KEY`, `DRAFT_API_TOKEN`, `OPENAI_API_KEY` 이름이 유지됨을 확인했습니다. Secret 값은 읽지 않았습니다.

위 초기 확인은 Luna 호출 성공이나 위치·cm 정확도 검증이 아닙니다. 이후 사용자가 실행한 2026-11-02(KST) 실제 Hoodie 측정의 저장 기록에서 `gpt-6-luna`·v1 모델 버전과 8개 visible 원시 관측을 확인했습니다. 양 어깨·양 소매끝 네 점은 실제 원단보다 배경 쪽에 있었고, 앱의 엄격한 마스크 검증에서 제외됐습니다. 해당 512×384 마스크와 후보의 차이는 약 1.4~2.6px였으며, 이 거리는 수동 정답 봉제점에 대한 오차나 cm 정확도를 뜻하지 않습니다. 결과를 통과시키기 위한 경계 허용오차는 적용하지 않았습니다. 아래의 판매글 사진 테스트와 이전 배포 기록은 별도 이력으로 보존합니다.

기존 공통 앱 인증과 서버의 OpenAI Secret을 그대로 사용하며 새 Secret은 필요하지 않습니다. 설치별·전체 호출 제한도 판매글 요청과 합산합니다. 내부 제한 키의 기존 `garment-autofill` 이름은 합산 한도를 유지하기 위해 변경하지 않았습니다. 기존 신뢰된 개발 토큰 호환 경로도 유지합니다.

요청에는 다음 세 필드만 허용합니다. `requestId`는 앱이 생성한 UUID 문자열이며, 모델에는 전달하지 않고 성공 응답에 서버가 그대로 복사합니다.

```json
{
  "requestId": "12345678-1234-4234-9234-123456789abc",
  "image": {
    "imageDataUrl": "data:image/jpeg;base64,<JPEG 사본>",
    "width": 1536,
    "height": 2048
  },
  "category": "Jacket"
}
```

- `category`: `Blazer`, `Jacket`, `Coat`, `Denim Jacket`, `Sports Jacket`, `Hoodie`(후드티), `Sweater`(스웨터·니트), `Polo`(폴로)만 허용합니다.
- 사진은 이미 올바른 방향으로 편 **전체 사진**이어야 합니다. 화면 표시용 크롭·패딩·가로세로 늘리기를 적용하지 않습니다. `width`와 `height`는 업로드 사본의 실제 픽셀 크기이며 1~16,384 정수입니다. Worker는 이 숫자의 형식·범위를 검증하며 전체 이미지 디코딩으로 크기를 재측정하지는 않습니다.
- 기존 JPEG/PNG/WebP 데이터 URL 검사와 한 장 2MiB, 요청 12MiB 제한을 적용합니다. 원본 사진·EXIF·GPS·깊이는 서버가 필요로 하지 않습니다.
- 좌표는 업로드 사진 전체 왼쪽 위 원점, x 오른쪽·y 아래 방향의 정규화 좌표이며 `0 <= x,y < 1`입니다. 앱은 업로드 방향을 원래 센서 방향으로 한 번 역변환한 뒤 기존 같은 프레임의 LiDAR 깊이와 연결해야 합니다.

성공 응답은 정확히 `requestId`, `schemaVersion`, `modelVersion`, `model`, `view`, `neckStyle`, `points`, `backNeckSeamCenter`를 갖습니다. 버전은 각각 `outerwear-landmarks-v1`, `luna-outerwear11-backseam-v1`, 모델은 `gpt-6-luna`로 서버에서 고정합니다. HTTP의 `X-Request-Id`는 별도의 서버 추적 ID입니다. 오류 응답의 `requestId` 역시 서버 추적 ID이며 성공 본문의 앱 요청 ID와 혼동하지 않습니다.

`points`에는 다음 11개 이름이 모두 있어야 하고 추가 이름은 허용하지 않습니다.

```text
neck_left, neck_right, shoulder_left, shoulder_right,
armpit_left, armpit_right, sleeve_end_left, sleeve_end_right,
hem_left, hem_center, hem_right
```

각 점과 별도 `backNeckSeamCenter`는 아래 둘 중 하나입니다. `visible`에는 유한한 범위 내 좌표가 필수이고, `occluded` 또는 `uncertain`에는 `point: null`이 필수입니다. 모델 출력이 이 관계를 어기거나 점 이름·enum·필드를 바꾸면 502 `invalid_ai_response`로 거부하며 좌표를 보정하거나 자동 재요청하지 않습니다.

```json
{"point":{"x":0.502,"y":0.897},"visibility":"visible"}
```

```json
{"point":null,"visibility":"occluded"}
```

`view`는 `front/back/unknown`, `neckStyle`은 `hood/collar/stand_collar/hood_and_collar/collarless/unknown` 중 하나입니다. 보이지 않는 점을 추측하지 않도록 일부 또는 전체 점이 null인 성공 응답도 허용합니다. 총장 규약은 뒷목 몸판 봉제선 중앙→뒤판 밑단이므로 `front/unknown`의 `backNeckSeamCenter`는 반드시 null·`uncertain`으로 반환하도록 지시합니다. 뒷면에서도 후드·칼라에 가린 뒷목 봉제선 중앙은 null이며, 칼라/후드 상단·실루엣 상단·양 목점 평균으로 채우지 않습니다. 앱 역시 정면·불명 뷰의 총장 시작점은 사용하지 않고 원시 관측만 보존합니다. `hem_center`는 보이는 몸판 중앙의 실제 밑단 경계이며, 옷 전체 최저점이나 양 밑단 점의 평균을 사용하지 않도록 지시합니다. 소매끝은 소맷단의 바깥 모서리입니다.

프롬프트와 JSON 스키마는 `src/garment-landmarks.js`에 있습니다. 사진 속 명령은 신뢰하지 않는 관찰 자료로 취급하며 촬영 안내, cm, 치수, 모델의 자기 신뢰도 숫자는 생성하지 않습니다. `store: false`, 엄격한 Structured Outputs, 도구 미사용, 30초 서버 타임아웃과 기존 오류 정제를 유지합니다. 형식 검증 통과는 봉제점 위치나 실측 정확도를 증명하지 않습니다.

검증은 `npm test`로 기존 판매글 회귀와 새 `test/landmarks.test.js`를 함께 실행합니다. 새 테스트는 후드티를 포함한 6개 허용 분류, 원본 요청 ID 보존, 공통 인증·합산 제한, 크기·좌표계 계약, 가려진 점, 뒷목 봉제선, 범위·enum·추가 필드 거부, 거절·불완전 응답·타임아웃을 검사하며 실제 OpenAI에 접근하지 않습니다.

## 아우터 측정점 v2 — 앞판 총장·개정 프롬프트, 원격 배포 완료

이전 v2 앱은 `POST /v2/garments/landmarks`를 요청합니다. 요청 본문과 인증·공유 호출 제한은 v1과 같고, 기존 `/v1/garments/landmarks`는 유지합니다. v2 성공 응답의 `schemaVersion`은 `outerwear-landmarks-v2`, `modelVersion`은 `luna-outerwear11-view-length-v2`이며, 기존 11개 점·`backNeckSeamCenter`에 **`frontNeckSeamCenter` 관측을 필수로 추가**합니다. 가려진 보조점은 필드를 생략하지 않고 기존과 같은 `{point:null,visibility:"occluded" 또는 "uncertain"}` 형식으로 보냅니다.

**2026-11-02 01:43(KST) `npm run deploy`의 Uploaded·Deployed 성공을 확인했으며, `dobby-openai`의 당시 배포 버전은 `6045afbc-f1e2-4b50-899d-2a6864578cc2`입니다.** 대상은 위와 같은 [dobby-openai Worker](https://dobby-openai.dobbyisvintage.workers.dev)입니다. 배포 후 원격 확인 범위는 다음과 같으며 실제 사진이나 유효한 인증을 포함한 Luna 요청은 보내지 않았습니다.

| 확인 요청 | 결과 | 확인 범위 |
|---|---|---|
| `GET /health` | 200 | Worker 실행 상태 |
| `OPTIONS /v2/garments/landmarks` | 405, `Allow: POST` | v2 경로가 인식됨. 앱에서 발생한 이전 404 해소 |
| 무인증 빈 JSON `POST /v2/garments/landmarks` | 401, `unauthorized` | 인증 없는 요청 거절 |

이 확인은 Luna 호출 성공이나 위치·cm 정확도 검증이 아닙니다. 현재 v2 앱에서 재촬영해 연결을 시험할 수 있으며, 기존 v1 배포와 사용자 측정 기록은 위에 별도 이력으로 보존합니다.

| 사진 면 | 총장 시작 관측 | 종점 | 앱 측정·제품 저장 |
|---|---|---|---|
| 정면 | `frontNeckSeamCenter`: 앞목 중앙 몸판 목둘레 부착/마감 봉제선 | 현재 앞판의 실제 `hem_center` | 앞판 총장 · `top.frontLength` · `frontLength` |
| 뒷면 | `backNeckSeamCenter`: 뒷목 중앙 몸판 목둘레 부착/마감 봉제선 | 현재 뒤판의 실제 `hem_center` | 기존 총장 · `top.totalLength` · `totalLength` |
| 불명 | 두 보조 관측 모두 null | 현재 보이는 중앙 밑단이 식별될 때만 관측 | 자동 총장 미확정 |

정면의 뒷목점, 뒷면의 앞목점은 null로 반환해야 합니다. 파서는 반대 면의 보조점에 좌표가 있으면 잘못된 응답으로 거절하고, 앱도 앞뒤 시작점을 서로 대체하지 않습니다. v1은 뒷목 보조점만 갖는 이전 의미 그대로 재열 수 있으며, v2 정면 길이는 기존 뒤판 총장 필드에 저장하지 않습니다. 상품 목록의 기존 총장 범위 필터와 기존 채널의 일반 총장 전용 필드에도 앞판 길이를 대입하지 않습니다. 앞판 총장은 별도 이름으로 제품 측정 목록에 표시합니다.

프롬프트는 어깨 봉제선과 소매 부착선이 외곽에서 만나는 실제 교차점, 커프의 실제 바깥 모서리, 현재 보이는 면의 중앙 밑단을 구체적으로 정의합니다. 목쪽은 후드 기부·칼라 밑부착선·스탠드 밑부착선·칼라리스 마감선을 구분하며 후드/카라 높이를 제외합니다. 열린 지퍼·중앙 트임·앞판 겹침의 빈 공간을 평균·대칭·가상 연결로 채우지 않습니다. 반환 전 좌표를 원본 사진에 다시 대응해 물리점을 확인하도록 지시하며, 임의의 안쪽 offset·스냅으로 통과시키지 않습니다. 이 지시는 정확도 개선을 위한 가설이며 위치 정확도를 보장하지 않습니다.

모델 `gpt-6-luna`, `detail: high`, reasoning `low`, 한 번의 요청과 기존 30초 서버 제한은 유지합니다. 앱은 원본 전체 사진에서 최대 2048px 사본을 만들어 보내며, 기존 960px 분석 이미지를 재사용하던 경로를 수정했습니다. **v2와 개정 프롬프트는 배포 완료됐지만 실제 Luna 사진 요청과 실사진 위치·LiDAR cm 정확도 평가는 아직 수행하지 않았습니다.** 개정 프롬프트와 고해상도 입력의 효과는 같은 사진·수동 정답 좌표로 별도 비교해야 합니다.

## 배포된 AI Worker에 OpenAI 키 입력하기

Cloudflare 팀 계정에서 `dobby-openai` → **Settings → Runtime variables and secrets**로 이동합니다. 현재 키는 등록돼 있으며, 아래는 추후 교체할 때의 입력 기준입니다.

- Type: **Secret**
- Variable name: **`OPENAI_API_KEY`**
- Value: 사용자가 OpenAI 팀 프로젝트에서 발급한 API 키를 직접 입력합니다.

Cloudflare 화면의 저장·배포 동작으로 반영합니다. `DRAFT_API_TOKEN`은 이미 등록돼 있으므로 새로 입력할 필요가 없습니다. OpenAI 키는 채팅·Git·Swift 코드·이 README에 넣지 않습니다. 키 등록 자체는 사진 분석 요청을 보내지 않습니다.

키 등록 후 사용자 승인으로 실제 사진 요청 2회를 실행했습니다. 아래의 `check:cloud` 명령은 별도 모의 Worker용이며 이 실제 AI 서버를 검사하는 명령이 아닙니다. 추가 유료 사진 분석은 사용자가 요청한 범위에서 진행합니다.

## 검증 결과

2026-10-31 공통 인증 수정은 자동 테스트 **146개 전체 통과**, 실제 AI용 설정의 `npm run dry-run` 통과로 확인했습니다. 정상 공통 인증, 인증 오류, 바인딩 누락·실패, 설치별·공통 제한 초과, 개발 토큰 호환을 검증하며 실제 OpenAI를 호출하지 않습니다. 사용자가 새 Secret을 등록했고, 승인 후 Cloudflare 배포와 위의 비용 없는 인증 검사를 완료했습니다.


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
- `DOBBY_APP_API_KEY`: 기존 Instagram 앱 접근 키와 동일한 값 (공통 앱 인증)
- `DRAFT_API_TOKEN`: 별도로 만든 긴 무작위 개발용 인증 토큰 (기존 연결 테스트)

`npm run dev:live`는 Worker를 로컬에서 실행하지만 실제 API 요청을 받으면 OpenAI를 호출하므로 사용료가 발생할 수 있습니다. 키 파일 등록만으로 호출하지는 않습니다. 추가 코드 배포는 코드·테스트 결과 확인 후 별도 승인 범위에서 진행합니다.

`DRAFT_API_TOKEN`은 개발자 연결 테스트용이며 앱 번들에 포함하지 않습니다. 일반 앱은 기존 Instagram 앱 접근 키와 자동 생성 설치 식별자를 사용합니다. 사용자 인증과 전역 과금 상한은 별도 검토가 필요합니다. 앱 화면 연결은 #122, 실제 연결·배포 준비는 #123 범위입니다.

실제 사진 요청의 Cloudflare CPU 한도 충족 여부는 후속 측정이 필요합니다. OpenAI에는 `store: false`로 요청하지만 이는 모든 데이터 보관 정책을 해제한다는 뜻은 아닙니다.

공식 문서: [Cloudflare 로컬 실행](https://developers.cloudflare.com/workers/local-development/), [비밀값 설정](https://developers.cloudflare.com/workers/configuration/secrets/), [OpenAI Docs — Luna](https://developers.openai.com/api/docs/models/gpt-6-luna), [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [사진 입력](https://developers.openai.com/api/docs/guides/images-vision).

## 앞판 중앙의 작은 벌어짐 추정 (v4)

앱의 새 촬영은 `/v4/garments/landmarks`를 사용하며 비교 실험의 부위 확대는 `/v4/garments/landmark-refinement`를 사용합니다. 모델은 기존 `gpt-6-luna`입니다. v1~v3 요청/저장 기록의 정의는 유지합니다.

`outerwear-landmarks-v4` / `luna-outerwear11-front-gap-v4`는 앞목 연결 봉제선 중앙과 `hem_center`에 한해 `visibility: estimated`를 허용합니다. AI는 중앙 벌어짐 양옆의 실제 앞여밈 끝점을 `centerSupport.frontNeckSeamCenter` / `centerSupport.hem_center`의 `left`, `right`로 반환하고 Worker가 산술 중점을 계산합니다. 직접 보이는 점이나 확인할 수 없는 점의 support는 명시적 `null`입니다. 윗점·아랫점은 독립적으로 처리합니다.

앱은 지지점의 원단 근접 여부(마스크 2픽셀), 작은 벌어짐(몸판 폭 20% 이하), 양끝 높이 차(몸판 높이 6% 이하), 중앙/목/밑단 위치를 검증합니다. 이는 보정 허용 조건이며 실측 오차 보증값이 아닙니다. 통과한 추정점은 마스크 밖이어도 중앙에 유지하고 같은 의류 평면에 투영합니다. 배경 깊이를 직접 사용하거나 마스크를 확대하지 않습니다. 기존 관측 밑단의 경계 보정은 estimated 점에 적용하지 않습니다.

저장 기록은 `centerEstimates`에 실제 지지점과 추정점을 보존하며 결과는 확인이 필요한 값으로 유지합니다. 앱의 총장 기준 식별자는 `center-front-neck-to-hem-small-gap-midpoint-v1`입니다. 이 변경은 Worker 배포와 앱 재빌드가 모두 필요합니다.

총장 윗점·밑점 중 하나라도 검증 후 빠져 있으면 앱은 `/v4/garments/length-refinement`를 한 번 요청합니다. 틈 감지 여부나 첫 분석 20초 조건으로 건너뛰지 않습니다. 이미 두 점이 유효하면 추가 요청하지 않습니다. 확대 처리는 인코딩을 포함해 최대 12초로 제한하며 촬영 전체 취소·제한 시간은 그대로 적용됩니다.

본문은 `{requestId, category, image, regions}`이며 전체 옷 참고 사진과 정확히 두 확대 영역 `upper`, `hem`을 보냅니다. 모델 응답은 `frontNeckSeamCenter`, `hem_center`, 두 점의 `centerSupport`, `view`, `neckStyle`만 요청합니다. 각 중앙점과 support는 해당 확대 사진의 정규화 좌표입니다. 서버 응답은 `refinementVersion: "outerwear-two-center-refinement-v4"`, `requestId`, `model`, `modelVersion`과 위 관측 필드이며 공용 11점 응답과 구분합니다. 이전 앱·비교 실험의 5부위 `/landmark-refinement` 계약은 유지합니다.

확대 응답에서는 빠졌던 총장점만 검증 후 채택하고, 최초 응답의 정상 총장점과 어깨·가슴·소매 점은 보존합니다. 확대 실패 시 최초 측정 결과를 유지하고 취소는 전파합니다. `remoteCenterRefinement`에 두 확대 영역·원본 관측·채택한 점을 저장합니다. 기존 기록과 함께 읽도록 저장용 `localResponse`의 다른 점은 null이며 새 AI 관측으로 취급하지 않습니다. Worker 배포 후 새 앱을 빌드해야 전용 경로가 사용됩니다.

## model-test: 새 목옆점 정의와 좌우 개별 확대 재분석

`POST /v4/garments/neck-refinement`는 `{requestId, category, image, regions}` 형식이며 `regions`에는 `upper` 한 장만 허용합니다. `image`는 전체 옷 참고용입니다. 반환값은 `refinementVersion: outerwear-side-neck-refinement-v1`, `modelVersion: luna-outerwear11-front-gap-v4`, `model`, `requestId`, `view`, `neckStyle`, `points`입니다. `points`는 `neck_left`, `neck_right` 두 개뿐이며 좌표는 **upper 확대 사진 기준**입니다. 목 형태별 정의는 `SIDE_NECK_INSTRUCTIONS`를 v4 첫 분석과 재분석에서 공유합니다.

재분석은 관측 가능한 교점은 `visible`, 주변 목둘레·어깨선의 진행으로 좁힐 수 있는 가려진 교점은 `estimated`로 구분합니다. 두 경우 좌표가 필요하며 `occluded`/`uncertain`은 null입니다. 기존 v4 전체 응답에 목옆점 estimated를 추가하지 않고 이 전용 응답에서만 허용합니다. 앞면이 아니면 좌표를 반환하지 않습니다. 기존 인증, 설치별/공유 요청 제한, 사진 용량 검증을 그대로 적용합니다.

새 앱은 첫 분석 후 목·어깨 통합 확대를 한 번(12초 제한) 요청하고, 그 결과의 좌우 목옆점 각각을 중심으로 두 개의 정사각형 확대를 추가 요청합니다(각 20초 제한). 개별 요청은 같은 경로에 `target: "neck_left"` 또는 `"neck_right"`를 추가합니다. 반대쪽 점은 null이어야 하며, 구버전의 target 없는 요청도 계속 지원합니다. 전체 촬영 처리 제한은 100초입니다. 마스크 검증을 통과한 대상 목옆점만 교체하고, 실패·null·검증 탈락은 직전 점을 유지합니다. 목옆점을 기준으로 마스크 밑단 교점을 계산하므로 밑단 AI 재분석은 하지 않습니다. 저장 진단 `remoteNeckRefinement`에는 크롭 범위·원본 응답·반영한 점·실패 여부가 남습니다.

적용 순서: 이 디렉터리에서 `npm test`, `npm run dry-run`, `npm run deploy` 후 앱을 다시 빌드합니다. 배포 전 새 경로의 실패는 앱에서 첫 분석으로 복귀하므로 확대 분석 개선은 적용되지 않습니다. 실제 사진의 위치 정확도는 배포 후 별도 확인해야 합니다.

좌우 개별 확대는 원본 정렬 이미지에서 각 AI 목옆점 중심으로 생성합니다. 정사각형 한 변은 `max(원본 폭 × 0.14, 좌우 AI 점 사이 픽셀 거리 × 0.95)`를 올림하고 이미지 안으로 제한합니다. 양쪽 크롭은 한쪽 재분석 결과가 다른 쪽 입력을 바꾸지 않도록 같은 시점의 예측으로 고정합니다. 저장 진단 `remoteNeckSideRefinements`는 대상 ID·크롭·원본 응답·채택 여부·실패를 보존하며 기존 기록에는 없어도 됩니다. 한 촬영당 최대 4회 호출이며 설치별 5회/60초 제한을 공유합니다.

새 카라 기준은 어깨 윗라인이 목 옆의 카라 뿌리로 이어지는 연결 지점입니다. 카라 앞끝·라펠 끝은 제외합니다. 좌우 확대 비교에서 일부 사진은 개선되고 일부는 악화됐으므로 실제 위치의 정확도를 보장하는 검증은 아닙니다. 기존 마스크 검증은 원단 근접/형상 검증이며, 올바른 목 구조를 선택했는지까지 보증하지 않습니다.
