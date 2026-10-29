# Dobby 의류 정보 초안 Worker

사진 요청을 받아 제품명·브랜드·설명·판매자 확인 메모를 반환하는 #121 API입니다.

**현재 기본 실행은 로컬 모의 응답입니다.** OpenAI API 키·Cloudflare 로그인·충전 없이 연결 흐름을 확인할 수 있습니다. 사진은 외부로 전송하지 않고, 입력한 사진과 무관한 고정 예시를 반환합니다. 실제 사진 분석 품질을 검증하는 단계는 아닙니다.

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

테스트와 실제 호출용 코드의 번들 확인:

```sh
npm test
npm run dry-run
```

`dry-run`은 번들만 만들고 배포하지 않습니다. 다른 포트가 필요하면 `npm run dev:mock -- --port 8788`로 실행하고 `DOBBY_LOCAL_PORT=8788 npm run check:local`로 검사합니다.

## 모의 모드와 실제 모드

| 구분 | 모의 모드 — 기본 실행 | 실제 모드 — 추후 연결용 |
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

## Cloudflare 연결 테스트용 배포 준비

별도 `wrangler.dev.toml`과 `src/connection-test.js`는 실제 Cloudflare HTTPS 연결 확인용입니다. 배포 대상 이름은 `dobby-garment-ai-dev`이고, 현재 구성 준비 단계이며 아직 배포하지 않았습니다.

이 진입점은 실제 OpenAI 키가 환경에 있어도 무시하고 고정된 모의 응답을 반환합니다. 공개 상태 확인 경로는 `mode: "connection-test"`와 `X-Dobby-AI-Mode: mock`으로 구분합니다. 사진 초안 요청에는 별도로 등록한 `DRAFT_API_TOKEN` 비밀값이 필요합니다. 공개된 로컬 토큰을 사용하지 않습니다.

```sh
# 배포하지 않고 파일만 검증
npm run dry-run:dev
```

실제 배포는 대상과 동작을 확인한 뒤 진행합니다. 배포 시 개발용 토큰을 무작위로 만들고, 로컬의 Git 제외 파일 `.dev.vars.connection-test`에 권한 600으로 보관한 뒤 Worker의 비밀값으로 등록합니다. OpenAI API 키 등록은 이 테스트에 필요하지 않습니다.

배포와 토큰 등록이 완료된 이후에는 다음 명령으로 실제 주소의 상태·사진 전송·인증·입력 검증을 확인할 수 있습니다.

```sh
npm run check:cloud -- https://dobby-garment-ai-dev.<계정주소>.workers.dev
```

이 스크립트는 모의 모드 확인 후에만 개발용 토큰을 전송하며 리다이렉트는 따르지 않습니다. 실행에는 해당 Worker의 실제 배포 주소가 필요합니다. 정상 요청도 고정된 연결 확인용 예시를 반환하므로 사진 분석 품질을 검증하지는 않습니다.

## 추후 실제 AI 연결 시

현재 이 단계는 실행하지 않았습니다. `.dev.vars.example`을 `.dev.vars`로 복사한 뒤 **사용자가 직접** 다음 값을 입력합니다. 이 파일은 Git에서 제외되며 키를 채팅에 붙여넣을 필요가 없습니다.

- `OPENAI_API_KEY`: OpenAI 프로젝트 API 키
- `DRAFT_API_TOKEN`: 별도로 만든 긴 무작위 개발용 인증 토큰

`npm run dev:live`는 Worker를 로컬에서 실행하지만 실제 API 요청을 받으면 OpenAI를 호출하므로 사용료가 발생할 수 있습니다. 키 파일 등록만으로 호출하지는 않습니다. 실제 배포는 코드·테스트 결과 확인 후 별도 단계로 진행합니다.

이 토큰은 개발자 연결 테스트용입니다. iOS 앱에 공통 토큰을 포함하지 않고, 사용자 배포 전에 요청 인증과 사용량 제한을 구현해야 합니다. 앱 화면 연결은 #122, 실제 연결·배포 준비는 #123 범위입니다.

Cloudflare 무료 플랜의 CPU 한도 충족 여부는 실제 배포 후 측정해야 합니다. OpenAI에는 `store: false`로 요청하지만 이는 모든 데이터 보관 정책을 해제한다는 뜻은 아닙니다.

공식 문서: [Cloudflare 로컬 실행](https://developers.cloudflare.com/workers/local-development/), [비밀값 설정](https://developers.cloudflare.com/workers/configuration/secrets/), [OpenAI Docs — Luna](https://developers.openai.com/api/docs/models/gpt-6-luna), [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [사진 입력](https://developers.openai.com/api/docs/guides/images-vision).
