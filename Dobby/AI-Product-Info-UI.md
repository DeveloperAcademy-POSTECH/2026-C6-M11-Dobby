# AI 제품 정보 입력 · A안 (#122)

사진 선택 화면의 **AI로 제품 정보 입력하기** 토글은 기본 ON입니다. 토글을 바꾸는 것만으로 요청하지 않으며, **다음**을 눌렀을 때 사진 저장 → AI 생성 → 제품 정보 입력 화면으로 이동합니다. OFF이면 기존 직접 입력 흐름을 사용합니다.

- 선택 순서대로 최대 5장을 AI에 전송합니다. 상품 사진은 기존처럼 최대 10장까지 유지합니다.
- 업로드용 사본만 최대 2,048px JPEG로 변환하고 방향을 보정합니다. 원본 사진과 메타데이터는 수정하지 않습니다.
- 제품명·설명·브랜드만 적용합니다. 설명의 문단 구분을 유지하고, 브랜드가 `null`이면 빈칸으로 표시합니다.
- `reviewNotes`는 판매 설명에 합치거나 화면에 표시하지 않습니다.
- 기존 내용이 있으면 교체 여부를 확인합니다. 실패 시 수동 재시도·직접 입력을 제공하고 자동 재시도는 하지 않습니다.
- 취소하거나 화면을 닫은 요청, 사진 선택이나 입력이 바뀐 요청의 결과는 적용하지 않습니다.
- 생성 도중 앱을 닫아도 사진과 초안은 남습니다. 초안을 다시 열었다고 자동으로 재요청하지 않습니다.

## 파일 역할

| 파일 | 역할 |
| --- | --- |
| `ProductPhotoSelectionView.swift` | 토글·생성 대기·취소·재시도·직접 입력 |
| `ProductCreationFlowView.swift` | 사진 저장·생성 호출·세 필드 적용·다음 화면 이동 |
| `ProductAutofillSession.swift` | 중복/늦은 응답 차단, 필드 변경 보호 |
| `ProductAutofillClient.swift` | 기존 `dobby-openai` Worker HTTP 호출·인증 주입·오류 처리 |
| `DobbyInstallationAuth.swift` | Instagram과 AI가 공유하는 앱 접근 키 확인·기기별 인증값 자동 생성/복원 |
| `ProductAutofillDevelopmentAuth.swift` | 기존 Debug 개발 토큰 연결의 선택적 호환 경로 |
| `ProductAutofillPhotoEncoder.swift` | 업로드 사진 변환·용량 제한 |
| `ProductInformationFields.swift` | 제품명·설명·가격·브랜드·실측 입력 필드 |

공통 생성 클라이언트와 세 필드 적용 로직은 이후 B안에서도 사용할 수 있습니다. 현재 UI는 A안이며 B안은 별도 작업입니다.

## 실제 API 연결과 인증

호출 주소는 기존 팀 Worker의 `https://dobby-openai.dobbyisvintage.workers.dev/v1/garments/autofill`입니다. OpenAI API 키와 프롬프트는 Worker에서 관리하며 앱에 포함하지 않습니다. 2026-10-31 승인 후 수정한 Worker를 배포했고 공통 인증이 통과하는 것을 확인했습니다. 앱은 이 브랜치의 인증 수정 코드로 다시 빌드해야 합니다.

### 팀원이 일반 Dobby 설정으로 실행

Debug·Release 모두 기존 Instagram 연동의 앱 설정을 사용합니다. 별도 AI 전용 설정 파일이나 개인 scheme, 기기별 개발 토큰 입력은 필요하지 않습니다.

1. 기존 `Config/DobbySecrets.xcconfig`의 `DOBBY_INSTAGRAM_APP_API_KEY`가 Info.plist의 `InstagramAppAPIKey`로 전달됩니다. 기존에 공유받은 앱 설정이 없는 Mac은 이 설정이 먼저 필요합니다.
2. 앱은 설치별 인증값을 Keychain에서 읽고, 없으면 32바이트 난수로 한 번 생성합니다. Instagram이 사용하던 service `com.dobby.instagram` / account `installation-token`을 유지하므로 기존 Instagram 연결의 식별자를 교체하지 않습니다. 중복 생성이 겹치면 먼저 저장된 값을 다시 읽습니다.
3. AI 요청에 `X-Dobby-App-Key: <기존 앱 접근 키>`와 `Authorization: Bearer <설치별 64자리 소문자 hex 인증값>`을 전송합니다. Instagram 로그인 완료 여부와 무관하게 준비할 수 있습니다.
4. Worker는 앱 키·인증 형식을 검사하고 호출 횟수 제한을 통과한 요청만 OpenAI로 전달합니다. 실패한 요청을 다른 인증 방식으로 자동 재시도하지 않습니다.

설치별 인증값은 해당 기기 Keychain에 저장하고 iCloud로 동기화하지 않습니다. 기존 Instagram 인증값은 그대로 사용합니다. OpenAI 키는 이 값들과 별개이며 Worker Secret에만 둡니다.

### Worker 반영 상태

- 사용자가 기존 `dobby-openai`에 Secret **`DOBBY_APP_API_KEY`**를 등록했습니다. 앱의 **`DOBBY_INSTAGRAM_APP_API_KEY`와 동일한 Instagram 앱 접근 키**를 사용하며 실제 인증 검사도 통과했습니다. Cafe24의 동명 설정과 혼동하지 않습니다.
- `wrangler.toml`의 `AI_INSTALLATION_RATE_LIMITER`와 `AI_SHARED_RATE_LIMITER` 바인딩이 포함된 수정 코드를 같은 Worker에 배포했습니다. 버전 `c2b63e32-62bb-4631-b01b-a5858c0dca51`에 트래픽 100% 적용과 기존 `OPENAI_API_KEY`·`DRAFT_API_TOKEN` 유지를 확인했습니다.
- 기본 제한은 설치별 60초에 5회, 공통 60초에 30회입니다. Cloudflare의 위치별 근사 제한이므로 전 세계 합산 과금 상한이 아닙니다.
- 앱도 수정된 코드로 다시 빌드해야 합니다. 배포 후 검사는 빈 사진 요청으로 인증만 확인했으며 실제 OpenAI를 호출하지 않았습니다. 앱 설치·실제 사진 생성은 아직 수행하지 않았습니다.

이 방식은 기존 앱 설정을 사용하는 팀 개발·테스트 연결입니다. 앱에 포함된 공통 키와 자가 생성 식별자가 실제 로그인 사용자나 정식 앱임을 증명하지는 않습니다. 사용자별 인증·정밀 과금 제한은 별도 범위입니다.

### 이전 개발 연결 호환

공통 앱 키 설정이 없는 Debug 앱만 기존 `DOBBY_AI_AUTH_TOKEN` 실행 환경 또는 개발 Keychain 토큰을 사용할 수 있습니다. 이 경우에만 개인용 `Dobby AI Local` scheme이 선택적 호환 수단으로 남습니다. 명시적 실행 환경 값이 있을 때만 앱 시작 시 개발 토큰을 저장하며, 일반 실행에서는 이 초기화와 개발 상태 파일 기록을 하지 않습니다.

Worker는 앱 키 헤더가 없는 기존 `DRAFT_API_TOKEN` 요청도 계속 지원합니다. 앱 키 헤더가 있으면 공통 인증만 검사하며, 잘못된 앱 키를 개발 토큰으로 우회하지 않습니다. 개발 토큰을 공유 코드·Info.plist·공유 scheme에 추가하지 않습니다. Release에서는 개발 토큰 경로를 사용하지 않습니다.

## 비용 없는 화면 검증

`--flow-preview --flow-test-store <임의 UUID> --garment-preview-top` 실행 인자와 `DOBBY_AI_FIXTURE_RESULT` 실행 환경 변수를 함께 사용하면 Debug 전용 테스트 응답을 사용합니다. 값은 `success`, `delay`, `failure`, `failure-once`입니다. 이 모드는 Worker와 OpenAI를 호출하지 않으며 테스트 측정값/이미지를 사용합니다. 일반 실행에서는 자동으로 활성화되지 않습니다.

```sh
bash Tools/run-ui-tests.sh 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:DobbyUITests/ProductAutofillFlowTests \
  -only-testing:DobbyPresentationTests/ProductAutofillClientTests \
  -only-testing:DobbyPresentationTests/ProductAutofillSessionTests \
  -only-testing:DobbyUITests/ProductPhotoSelectionGridTests
```

## 공통 인증 검증 결과

2026-10-31: iOS 인증 관련 33개 테스트(클라이언트·공통 설치 인증·기존 개발 인증), A안 AI ON/OFF 화면 테스트 2개가 모두 통과했습니다. 인증 테스트는 메모리 저장소와 HTTP stub을 사용하며 실제 Keychain·OpenAI에 접근하지 않습니다. 화면 검증도 명시적 fixture를 사용합니다. 기본 `Dobby` scheme의 실제 기기 대상 Release 빌드(코드 서명 제외)와 Worker `dry-run`도 통과했습니다. 원격 Worker 배포 후 상태 확인 200, 정상 공통 인증 + 빈 사진 요청 400 `invalid_request`, 잘못된 공통 인증 401 `unauthorized`도 확인했습니다. 실제 기기에 설치하거나 실제 사진으로 AI를 호출하지 않았습니다.
