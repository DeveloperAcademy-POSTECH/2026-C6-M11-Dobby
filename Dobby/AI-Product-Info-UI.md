# AI 제품 정보 입력 · A/B 흐름 (#122)

설정 → 기본 설정 → **AI 생성 방식**에서 **A안(사진 선택 뷰 토글)** 또는 **B안(제품 정보 입력 뷰)** 중 하나를 선택합니다. 기본값은 A안이며 선택은 앱 재실행 후에도 유지됩니다. 설정 변경 자체로 AI를 호출하지 않습니다.

| 설정 | 사진 선택 화면 | 제품 정보 입력 화면 |
| --- | --- | --- |
| A안 | 기존 AI 토글 표시. 토글 ON에서 다음을 누르면 생성 후 이동 | 생성 결과가 채워진 화면. 토글 OFF이면 직접 입력 |
| B안 | AI 토글 없이 선택한 사진을 저장하고 다음 화면으로 이동 | 사진 위의 **AI로 제품 정보 생성하기** 버튼을 눌렀을 때 생성·입력 |

B안 버튼은 Figma `3632:15529`의 위치·주황색·16pt 모서리·sparkles 심볼·14pt Pretendard 글꼴을 기존 앱 스타일에 맞춰 구현합니다. 제품 사진은 사용자가 선택한 동적 사진을 유지합니다. 버튼을 누르면 기존 생성 중 안내와 취소 버튼이 표시되고, 완료 후 같은 입력 화면에 머뭅니다.

A/B 선택은 새 제품 작성 또는 초안 이어쓰기를 열 때 적용하고, 진행 중에는 해당 방식을 유지합니다. 저장된 초안을 열 때는 현재 설정을 사용하되 기존 입력과 A안 토글 선택은 보존하고 자동 생성은 하지 않습니다. 보관함의 완료 제품 수정 화면은 이 설정의 대상이 아닙니다.

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
| `ProductCreationFlowView.swift` | A/B 진입 분기·공통 생성/적용/저장·A안의 화면 이동 |
| `InfoInputView.swift` | B안 버튼·생성 대기·취소·재시도·직접 입력·덮어쓰기 확인 |
| `ProductAutofillFlowPreference.swift` | 기본 A·전환 설정 저장·테스트용 설정 격리 |
| `SettingsView.swift` | AI 생성 방식의 A/B 선택 행 |
| `ProductAutofillSession.swift` | 중복/늦은 응답 차단, 필드 변경 보호 |
| `ProductAutofillClient.swift` | 기존 `dobby-openai` Worker HTTP 호출·인증 주입·오류 처리 |
| `DobbyInstallationAuth.swift` | Instagram과 AI가 공유하는 앱 접근 키 확인·기기별 인증값 자동 생성/복원 |
| `ProductAutofillDevelopmentAuth.swift` | 기존 Debug 개발 토큰 연결의 선택적 호환 경로 |
| `ProductAutofillPhotoEncoder.swift` | 업로드 사진 변환·용량 제한 |
| `ProductInformationFields.swift` | 제품명·설명·가격·브랜드·실측 입력 필드 |

A/B는 같은 생성 세션·API 클라이언트·세 필드 적용 및 저장 로직을 공유합니다. B안은 기존에 배포한 인증과 API를 그대로 사용하므로 이 화면 변경에 따른 Worker 수정은 없습니다.

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
  -only-testing:DobbyUITests/ProductAutofillBFlowTests \
  -only-testing:DobbyPresentationTests/ProductAutofillFlowPreferenceTests \
  -only-testing:DobbyPresentationTests/ProductAutofillClientTests \
  -only-testing:DobbyPresentationTests/ProductAutofillSessionTests \
  -only-testing:DobbyUITests/ProductPhotoSelectionGridTests
```

## 공통 인증 검증 결과

2026-10-31: iOS 인증 관련 33개 테스트(클라이언트·공통 설치 인증·기존 개발 인증), A안 AI ON/OFF 화면 테스트 2개가 모두 통과했습니다. 인증 테스트는 메모리 저장소와 HTTP stub을 사용하며 실제 Keychain·OpenAI에 접근하지 않습니다. 화면 검증도 명시적 fixture를 사용합니다. 기본 `Dobby` scheme의 실제 기기 대상 Release 빌드(코드 서명 제외)와 Worker `dry-run`도 통과했습니다. 원격 Worker 배포 후 상태 확인 200, 정상 공통 인증 + 빈 사진 요청 400 `invalid_request`, 잘못된 공통 인증 401 `unauthorized`도 확인했습니다. 실제 기기에 설치하거나 실제 사진으로 AI를 호출하지 않았습니다.

## A/B 화면 구현 검증 결과

2026-10-31: A안 화면 테스트 5개, B안 화면 테스트 6개, 클라이언트·생성 세션·설정·초안 저장 테스트 36개에서 각 사례의 통과를 확인했습니다. B안의 생성 전 빈 입력, 버튼 호출·로딩·세 필드 적용, 실패 후 재시도·직접 입력, 설정 재실행 유지와 A안 복귀, 취소 후 늦은 응답 차단을 검증했습니다. 기존 내용 교체 확인창을 닫으면 입력이 유지되고, 교체해도 가격·소수점 실측 입력은 보존되며 기존 실측 저장 오류 안내도 정상 표시됩니다.

초기 교체 확인창 테스트는 네이티브 팝오버에서 취소 버튼 대신 바깥 영역으로 닫는 동작을 반영하지 못해 실패했습니다. 테스트 선택 조건만 보완한 뒤 해당 사례와 버튼 생성 사례를 단독 재실행해 모두 통과했습니다. 전체 실행의 마지막 결과 수집은 멈춰 종료했으며, 위 수치는 완료된 테스트 로그와 단독 재실행 결과를 합산한 사례 수입니다.

기본 `Dobby` scheme의 시뮬레이터 Debug 빌드와 기기 대상 Release 빌드(코드 서명 제외)를 통과했습니다. 시뮬레이터 캡처에서 Figma의 버튼 위치·색상·아이콘·글꼴과 기존 생성 중 안내를 확인했습니다. 화면 테스트는 명시적 fixture를 사용해 실제 Worker·OpenAI 호출과 과금이 없었습니다. B안 작업으로 Worker·프롬프트·인증 설정은 변경하지 않았습니다.
