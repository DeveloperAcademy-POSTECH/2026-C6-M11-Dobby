# 옷 인식 · 실측 촬영 화면

## 실행

앱 홈에서 **옷 촬영 · 실측**을 누른다. 측정 실험실에서 **실측 촬영**을 누른다. 촬영 전에 옷 종류를 선택할 필요 없이 카메라가 상의·하의를 판별한다.

홈에는 **상품 정보 빠른 복사 · 후르츠 우선**과 **내보내기 채널**도 함께 표시된다. 측정 실험실 상단의 **닫기**는 홈으로 돌아간다. 실측 또는 내보내기 화면을 보고 있을 때 `dobby-copy` 링크를 받으면, 열려 있는 화면을 닫은 뒤 상품 정보 복사 화면으로 이동한다. 촬영 미리보기처럼 실험실에서 연 화면도 함께 닫힌다.

1. 옷 한 벌을 바닥에 펼치고 소매·목·허리·밑단까지 전체가 보이도록 비춘다.
2. 같은 RGB 영상에서 의류 분류 모델로 종류를 판별하고, 해당 측정점 모델의 구조와 Vision의 전경 마스크를 함께 확인한다. 종류가 확인되면 상의 또는 하의 안내와 옷 모양의 파란 윤곽, 반투명 채움이 표시된다.
3. 영역·가장자리 깊이와 카메라 안정성 조건까지 충족하면 촬영 버튼이 활성화된다.
4. 촬영한 RGB·깊이를 고정하고, 그 사진에서 옷 종류·측정점·마스크를 다시 확인한다. 고정된 사진에서 확인한 종류에 맞는 측정 항목을 사용한다.
5. 실측 결과의 사진 위에 실제 점·측정선·cm 값이 표시된다. 계산 불가 항목은 수치 대신 원인을, 불확실한 항목은 확인 필요 상태를 표시한다.
6. **확인**은 사진·깊이·측정점·결과를 로컬 보관함에 저장한 뒤 촬영 화면을 닫는다. 뒤로 버튼은 재촬영한다.

사진 왼쪽 위 축소판은 원본 확대 보기, 치수 버튼은 항목 상세 보기로 연결된다. 상세의 수동점 검증은 기존 검증 화면을 사용하며 별도 기록으로 저장된다.

## 지원 범위

- 하의는 번들 `bottom7` 모델의 바지·반바지, 상의는 `top11` 모델의 펼친 긴팔·반팔 상의에 연결되어 있다.
- 종류는 카메라가 자동으로 판별한다. 옷 종류 또는 모델 버전이 바뀌면 촬영 준비의 연속 확인을 다시 시작한다. 판별이 불확실하면 성공 상태나 임의의 실측값을 표시하지 않는다. 자세한 선택 기준과 검증은 [상·하의 자동 판별](Automatic-Garment-Recognition.md)을 참고한다.
- 상의는 어깨너비·가슴 단면·밑단 단면·왼쪽/오른쪽 소매길이·총장 6개 항목을 제공한다. 자세한 기준은 [상의 모델 연결](Top-Recognition.md)을 참고한다.
- 대부분의 측정값은 지정된 점 사이의 3D 직선거리다. 상의 총장은 목 양끝의 3D 가로축 방향 성분을 제외한다. 주름을 펼친 길이나 굽은 봉제선 길이를 복원하는 기능은 아니다.
- LiDAR가 없는 기기와 시뮬레이터의 실제 촬영 경로에서는 실측값을 생성하지 않는다.

## 화면 미리보기

**촬영 화면 미리보기**는 합성 하의 그림과 합성 깊이로 세 화면의 전환을 확인한다. UI 테스트의 `--garment-preview-top` 실행 인자는 합성 상의 그림을 사용한다. **인식 상태 보기** → 셔터 → 결과 → 확인 순서다. 카메라·ML·센서 정확도 검증이 아니며, 화면과 저장 출처 모두 합성으로 구분된다.

UI 테스트의 `--garment-preview-partial` 실행 인자는 합성 미리보기의 일부 점을 제거해 부분 실패 표시를 검사한다. 실제 촬영에는 영향을 주지 않는다.

`--garment-preview-reduce-motion`은 합성 미리보기에서만 동작 줄이기 표시를 검사한다. 시스템 접근성 설정은 변경하지 않는다.

## 구현 경로

- `UI/GarmentCaptureFlowView.swift`: 촬영 상태, 취소·회전·복귀, 촬영부터 결과까지 연결.
- `UI/GarmentMeasurementResultView.swift`: 실제 사진·측정선·치수, 상세·확대·저장.
- `UI/LiDARCameraView.swift`: 공유 ARKit 미리보기와 실루엣 좌표 변환.
- `Capture/LiveForegroundAnalyzer.swift`: 한 번에 한 RGB 프레임의 모델 추론·전경 분할.
- `Capture/GarmentForegroundMaskAnalyzer.swift`: 원본 이미지에 정합된 Vision 마스크.
- `Capture/AutoGarmentLandmarkProvider.swift`: 같은 이미지의 의류 분류 결과·해당 측정점 모델·실측 항목을 함께 연결.
- `Capture/CoreMLGarmentLandmarkProvider.swift`: 개별 모델의 추론과 사진 진단.
- `Core/AutomaticGarmentKind.swift`, `Core/GarmentClassifierRoutingPolicy.swift`, `Core/GarmentKindSelectionPolicy.swift`: 종류 메타데이터와 판별 정책.
- `Core/TopLandmarkSchema.swift`: 상의 11점 계약과 실측 6개 정의.
- `Core/GarmentMaskAssociation.swift`: 인식점과 마스크의 일치 여부 검증.
- `Core/GarmentSilhouetteGeometry.swift`: 실제 픽셀 경계 추적. 오목한 부분·구멍을 보존한다.
- `Core/GarmentSilhouettePresentationGeometry.swift`, `UI/GarmentSilhouetteLayerRenderer.swift`: 표시용 윤곽 다듬기와 iOS 네이티브 전환. [윤곽 표시 개선](Garment-Silhouette-Presentation.md)에 구현·검증을 정리했다.

실시간 마스크를 다른 촬영 프레임의 측정에 재사용하지 않는다. 모델과 마스크의 매칭 허용 범위는 인식 확인용이며, 측정용 마스크를 팽창시키지 않는다. 방향 변경·움직임·분석 만료는 오래된 인식 결과를 무효화한다.

## 디자인 기준

Figma 파일 `T6tio8A3IQ9oP8FzASv6WK`의 세 화면:

- [인식 전 · 918:1483](https://www.figma.com/design/T6tio8A3IQ9oP8FzASv6WK/?node-id=918-1483)
- [인식 후 · 946:2257](https://www.figma.com/design/T6tio8A3IQ9oP8FzASv6WK/?node-id=946-2257)
- [실측 결과 · 946:2317](https://www.figma.com/design/T6tio8A3IQ9oP8FzASv6WK/?node-id=946-2317)

연결 계정의 디자인 데이터 접근이 거절되어, 사용자의 명시적 지시에 따라 데스크톱에 보이는 화면을 기준으로 구현했다. 색상·간격·셔터 스타일은 화면 관찰에 따른 근사이며 토큰·에셋 원본을 추출한 결과가 아니다. 사진·윤곽·치수는 동적 데이터이며 디자인의 재킷 사진이나 예시 치수를 앱 결과로 사용하지 않는다.

## 검증 명령

```sh
swift test --scratch-path /tmp/dobby-garment-core
xcodebuild -project Dobby/Dobby.xcodeproj -scheme Dobby \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/dobby-garment-device CODE_SIGNING_ALLOWED=NO build
Tools/run-ui-tests.sh \
  'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -only-testing:DobbyUITests/GarmentCaptureFlowTests
```

### 확인 결과 · 2026-09-30

- iOS 기기용 빌드 성공 (`CODE_SIGNING_ALLOWED=NO`; 실기기 설치 검증은 아님).
- 상의 방향 회복·부분 측정점 처리·처리 속도 보완 후 Core 테스트 312개 통과, 실패 0.
- iPhone 17 Pro / iOS 26.4 시뮬레이터의 서로 다른 UI 테스트 9개 통과. 상의 선택·사진 테스트·6개 치수 표시·저장 재열기, 직접 수동점 확인, 기존 하의 촬영·사진 검사·실시간 안내·합성 연결 결과 재열기를 포함한다.
- 인식 전·후 전환, 8개 치수 라벨의 비중첩 배치, 사진 확대, 항목 상세, 재촬영, 저장 후 기록 열기, 부분 실패, 가로 화면, 미지원 기기의 촬영 차단을 검증했다.
- 실제 반바지 사진 한 장을 4방향으로 회전해 모델·마스크 좌표 복원을 확인했다. 기준 방향 대비 마스크 IoU는 0.9965 이상, 점 차이는 640 입력 기준 최대 약 0.25px였다. 이는 좌표 처리 검증이며 센서 정확도나 일반적인 인식률의 근거가 아니다.

실제 iPhone의 카메라 영상과 실루엣 정합, 지속 촬영의 응답성, 줄자 대비 cm 오차는 별도 실기기 검증 대상이다.

실기기 오류 로그의 원인 구분과 최신 구현·검증 한계는 [상의 인식·촬영 흐름 개선](Garment-Recognition-Improvements.md)에 정리했다.

### 윤곽 표시 후속 개선 · 2026-10-01

사선의 계단 경계를 다듬고 같은 옷의 작은 변화에 0.22초 iOS 네이티브 전환을 적용했다. 인식 안내는 배경색만 전환하며 회전·인식 해제·동작 줄이기를 즉시 반영한다. Core 325개, 시뮬레이터의 서로 다른 UI·표시 테스트 17개와 기기용 빌드가 통과했다. 표시 전용 처리·검증 근거는 [윤곽 표시 개선](Garment-Silhouette-Presentation.md)을 참고한다.

### 공통 홈 연결 검증 · 2026-10-01

- 홈의 실측·빠른 복사·내보내기 메뉴와 화면 닫기·복귀를 확인했다.
- 실측·내보내기·중첩 촬영 미리보기에서 실제 `dobby-copy://home` 링크를 전달해 모든 모달을 닫고 복사 화면에 진입하는 것을 확인했다. 새 세션 ID의 복사 요청 링크는 만료 안내를 표시하며 실제 복사는 실행하지 않는다.
- Core 325개와 기존 빠른 복사 로직 검사가 통과했다. 라우팅 5개·기존 촬영 UI 3개·윤곽 표시 9개로 서로 다른 17개가 통과했다.
- 네이티브 프로젝트의 Debug·Release 기기용 빌드가 서명 없이 통과했다. 생성된 앱에서 카메라 권한 설명·Live Activity·URL 스킴과 QuickCopyWidget 포함을 확인했다.
- 실측 모듈은 통합 전 커밋과 동일하고, main의 판매 플랫폼·빠른 복사 소스도 보존했다. UI runner는 앱 plist와 색상 심볼 설정을 네이티브 프로젝트에 맞췄다.

상세 실행 기록은 [공통 홈 연결 검증](Validation/main-integration-2026-10-01.json)에 있다. 이 검증은 실제 기기의 센서·cm 정확도나 외부 플랫폼의 상품 등록·붙여넣기를 검증한 결과가 아니다.

### 상·하의 자동 판별 · 2026-10-01

촬영 전 종류 선택을 없애고 제공된 15종 의류 분류 모델과 기존 상·하의 측정점 모델을 연결했다. 고정된 촬영 사진에서 종류를 다시 판별하며, 인식 종류가 바뀌면 준비 상태를 다시 확인한다. Core 360개, 서로 다른 UI·표시 테스트 23개, iOS 번들 분류 모델 테스트 1개와 네이티브 Debug·Release 빌드가 통과했다.

실제 사진 26장 중 21장을 인식했다. 잘못된 상·하의로 통과한 사진은 없지만, 하의 4장과 상의 1장은 기존 점·윤곽 근거 부족으로 거절했다. 시뮬레이터의 전체 모델 준비에는 Vision 오류가 남아 있으며 실물 카메라·센서 검증은 포함하지 않는다. 자세한 구현·실행 범위와 미인식 사례는 [상·하의 자동 판별](Automatic-Garment-Recognition.md)을 참고한다.
