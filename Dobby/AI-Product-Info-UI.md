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
| `ProductAutofillDevelopmentAuth.swift` | Debug 실행 인증 전달·기기 전용 Keychain 저장·재실행 복원 |
| `ProductAutofillPhotoEncoder.swift` | 업로드 사진 변환·용량 제한 |
| `ProductInformationFields.swift` | 제품명·설명·가격·브랜드·실측 입력 필드 |

공통 생성 클라이언트와 세 필드 적용 로직은 이후 B안에서도 사용할 수 있습니다. 이 브랜치는 A안만 포함하며, B안은 이 브랜치 위에서 분기해 함께 검토할 수 있습니다.

## 실제 API 연결과 인증

호출 주소는 기존 팀 Worker의 `https://dobby-openai.dobbyisvintage.workers.dev/v1/garments/autofill`입니다. OpenAI API 키와 프롬프트는 계속 Worker에서 관리하며 앱에 포함하지 않습니다. 이 작업은 Worker를 수정하거나 배포하지 않습니다.

현재 Worker는 개발용 `DRAFT_API_TOKEN` 인증을 요구합니다. Debug 앱은 **실행 시 환경 변수 `DOBBY_AI_AUTH_TOKEN`**으로 전달받고, **앱이 시작하자마자 기기 전용 Keychain에 저장·검증**합니다. AI 요청 전에 디버그 연결이 끊어지더라도 이후 홈 화면에서 다시 실행하거나 일반 `Dobby` scheme으로 실행하면 같은 기기의 저장된 인증값을 사용합니다. 토큰 값은 Swift 코드, Info.plist, xcconfig, 공유 Xcode scheme, 앱 번들, 저장소에 넣지 않습니다. 이 값은 OpenAI API 키가 아닙니다.

### 실제 아이폰에서 Xcode로 실행

이 Mac에는 개인용 **Dobby AI Local** scheme을 준비했습니다. Xcode 상단 scheme을 `Dobby AI Local`, 실행 대상을 연결된 아이폰으로 선택하고 Run(⌘R)하면 됩니다. 사진 선택 화면에서 AI 토글을 켠 뒤 다음을 누르면 실제 팀 Worker를 호출합니다.

개인용 scheme은 Git에서 제외된 `Dobby/Dobby.xcodeproj/xcuserdata/<사용자>.xcuserdatad/xcschemes/`에만 저장되며 파일 권한은 600입니다. 토큰이 들어 있는 **Edit Scheme → Environment Variables 화면을 공유하거나 캡처하지 마세요.**

설정을 다시 만들어야 할 때는 로컬 Worker 개발용 인증 파일이 준비된 상태에서 다음 명령을 실행합니다. 기존 공유 scheme은 변경하지 않고 개인용 실행 설정만 생성·갱신합니다. 비밀값은 출력하지 않습니다.

```sh
python3 Tools/configure-ai-development-auth.py
```

아이폰에서 앱을 삭제하거나 인증값이 바뀌면 개인용 scheme으로 다시 실행해 기기 인증을 갱신합니다. Keychain 항목은 iCloud와 동기화하지 않습니다.

Debug 앱은 `Documents/dobby-ai-auth-status.json`에 인증 준비 여부, 실행 환경 존재 여부, 저장된 인증 존재 여부, 저장 성공 여부와 확인 시각만 기록합니다. 인증값과 일부 문자열, 전체 실행 환경, 원본 오류는 기록하지 않습니다. 실제 기기에서 실행 환경 값 없이 재실행했을 때도 `readiness: true`, `runtimePresent: false`, `storedCredentialPresent: true`가 되는지 확인합니다. UI 테스트와 테스트 호스트에서는 시작 시 초기화를 건너뜁니다.

### 시뮬레이터에서 직접 실행

실제 시뮬레이터 앱에 연결할 때는 빌드·설치 후 별도의 로컬 터미널에서 아래처럼 입력할 수 있습니다. `booted` 대신 원하는 시뮬레이터 UUID를 사용할 수 있습니다. 입력값은 화면과 셸 명령 기록에 남지 않습니다.

```zsh
read -rs 'dobby_preview_token?Worker 개발용 인증 토큰: '; print
xcrun simctl terminate booted com.dobby.Dobby 2>/dev/null || true
SIMCTL_CHILD_DOBBY_AI_AUTH_TOKEN="$dobby_preview_token" xcrun simctl launch booted com.dobby.Dobby
unset dobby_preview_token
```

유효한 실행 환경 값이 우선이며, 없으면 기기 Keychain을 읽습니다. 둘 다 없으면 기기 인증 누락 안내와 직접 입력을 제공하며 테스트 응답으로 바꾸지 않습니다. Worker의 OpenAI 연결 설정 오류는 기기 인증 누락과 다른 안내로 구분합니다. Release의 실제 사용자 인증은 #123에서 제공할 인증 공급자를 주입해야 합니다. 공유 개발 토큰을 앱에 포함하는 방식으로 배포하지 않습니다.

## 비용 없는 화면 검증

`--flow-preview --flow-test-store <임의 UUID> --garment-preview-top` 실행 인자와 `DOBBY_AI_FIXTURE_RESULT` 실행 환경 변수를 함께 사용하면 Debug 전용 테스트 응답을 사용합니다. 값은 `success`, `delay`, `failure`, `failure-once`입니다. 이 모드는 Worker와 OpenAI를 호출하지 않으며 테스트 측정값/이미지를 사용합니다. 일반 실행에서는 자동으로 활성화되지 않습니다.

```sh
bash Tools/run-ui-tests.sh 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:DobbyUITests/ProductAutofillFlowTests \
  -only-testing:DobbyPresentationTests/ProductAutofillClientTests \
  -only-testing:DobbyPresentationTests/ProductAutofillSessionTests \
  -only-testing:DobbyUITests/ProductPhotoSelectionGridTests
```
