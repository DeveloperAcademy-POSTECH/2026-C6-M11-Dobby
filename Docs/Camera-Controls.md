# LiDAR 실측 카메라 조작 — Issue #66

브랜치: `feat/66-camera-controls`

## 현재 지원 범위

| 기능 | 동작 |
| --- | --- |
| 터치 초점 | 미리보기 터치를 실제 센서 좌표로 변환하고 ARKit의 primary camera에 자동 초점을 요청한다. 노란 사각형은 요청이 받아들여진 위치를 표시한다. |
| 노출 보정 | 기기가 보고한 EV 범위 안에서 0.1 EV 단위로 조절한다. 초기화 버튼은 0 EV를 요청한다. |
| 1× | 기존 RGB·LiDAR 프레임을 사용한다. |
| 2× | 동일 프레임의 RGB·깊이·신뢰도를 정확히 같은 중앙 영역으로 자른다. 광학 2× 렌즈 전환이 아니다. |
| 0.5× | 현재 ARKit 측정 경로에서는 지원하지 않는다. 버튼은 비활성화되며 접근성 설명에도 지원하지 않음을 표시한다. |

셔터는 옷 인식이나 AF/AE 완료를 기다리는 조건을 추가하지 않았다. 기존처럼 사진과 깊이를 먼저 확보하고, 촬영한 데이터로 측정점을 추론한다. 촬영 중에는 설정을 변경하지 못한다.

합성 미리보기의 노란 사각형·EV·확대는 UI 검증용이다. 고정된 1× 합성 측정 데이터를 2× 촬영 결과로 저장하지 않도록 합성 2×에서는 셔터를 비활성화했다. 실제 카메라의 2× 촬영에는 이 제한이 없다.

## 좌표와 캡처 정합

### 터치 위치

`ARFrame.displayTransform`의 역변환을 사용해 화면의 회전과 aspect-fill 크롭을 되돌린다. 동일한 변환으로 표시 위치도 계산한다. 이미지 방향을 다시 적용해 이중 회전하지 않는다.

2×에서는 실제 미리보기 UIView의 크기를 확대하고 중앙을 보여 준다. 터치도 그 UIView의 좌표에서 변환하므로 확대 보정을 다시 적용하지 않는다. 잘린 영역, 잘못된 변환, 범위 밖 입력은 거부한다. 회전·확대·세션 변경 시 이전 노란 표시를 지운다.

### 2× 이미지와 깊이

예: RGB 1920×1440, 깊이 256×192일 때:

- RGB: 원점 (480, 360), 크기 960×720
- 깊이·신뢰도: 원점 (64, 48), 크기 128×96
- 보정값: `fx`, `fy` 유지, `cx -= 480`, `cy -= 360`, 기준 해상도 960×720

깊이를 새로 보간하거나 해상도를 늘리지 않는다. RGB와 깊이에서 정확히 대응하는 정수 크롭을 만들 수 없는 형식은 2× 지원 목록에 넣지 않는다. 프레임의 시간·세션·식별자는 유지한다. 평활화 깊이도 같은 크롭을 적용할 수 있을 때만 함께 보존한다.

후보 프레임 품질은 저장할 중앙 깊이 영역으로 평가한다. 중앙 깊이가 누락된 프레임이 배경의 좋은 깊이 때문에 선택되지 않도록 한다. 기존 0.35초 후보 선택 구간과 4초 제한은 유지한다.

2×는 표시와 저장 영역을 줄이는 기능이다. LiDAR 자체의 공간 해상도나 물리적인 측정 정확도가 두 배가 되는 것은 아니다.

## 설정 순서와 수명

하나의 직렬 큐에서 ARKit 소유 카메라에 짧게 설정을 적용한다. UI 동작에서 명령을 즉시 큐에 넣고, 셔터는 앞서 들어간 명령이 처리된 뒤의 새 RGB·깊이 프레임을 선택한다. 설정 적용 중 별도의 카메라 세션을 열지 않는다.

세션 UUID와 요청 식별자로 이전 초점·노출 완료가 현재 UI를 덮어쓰지 못하게 한다. 중단·실패·재시작 때 연결 상태와 대기 요청을 초기화한다. 취소된 EV 요청은 슬라이더에 남기지 않는다.

## 저장 정보의 의미

`CaptureSnapshot.cameraSettings`에 설정 정보와 정확한 크롭 정보를 함께 보존한다. 기존 스냅샷은 이 필드가 없어도 읽을 수 있다.

- `focusSensorPoint`: 카메라가 받아들인 명시적인 초점 위치. AF 완료를 보증하지 않는다.
- `requestedExposureBias`: 사용자가 요청한 값.
- `acceptedExposureBias`: 기기에 전달한 노출 목표값. AE가 이미 안정됐다는 뜻이 아니다.
- `frameExposureDurationSeconds`, `frameExposureOffsetEV`: 실제 선택된 ARFrame의 관측값.
- `crop`: 원본과 결과 이미지·깊이 크기 및 크롭 원점. 잘못 변조된 크롭 정보는 디코딩 단계에서 거부한다.

## 검증과 남은 확인

- 핵심 테스트 494개 통과: 좌표 변환, 상태 검증, 크롭 정합, 기존 측정 계산 포함.
- 카메라 worker·저장 메타데이터 테스트 9개, UI·기존 촬영 흐름 테스트 5개 통과. 안내 문구를 StaticText로 찾던 테스트 조회 오류를 수정한 뒤 해당 테스트를 재실행해 통과했다.
- 앱과 위젯의 iOS Simulator 및 실제 iPhone용 ARM64 Release 빌드 성공(서명·설치 제외). 세로·가로 UI 스크린샷에서 초점 표시·EV·화각·셔터 배치를 확인했다.
- 합성 평면과 기울어진 표면의 네 이미지 방향에서 2× 전후 3차원 위치·길이가 유지됨을 검증했다. 이 수학적 검증은 실기기의 cm 오차를 뜻하지 않는다.
- 좋은 바깥 깊이·누락된 중앙 깊이의 회귀 사례에서 중앙 ROI 기준 후보 선택과 요약 기록을 확인했다.
- 시뮬레이터 검증은 실제 센서의 AF/AE 동작을 입증하지 않는다. 실제 iPhone 17 Pro에서 초점 위치, EV 밝기 변화, 동일 옷의 1×/2× 치수 오차를 확인해야 한다.

실기기 확인은 같은 위치의 옷을 대상으로 1×/2×, 세로/가로, 밝은/어두운 조명에서 반복한다. 줄자로 확인한 정답과 비교하고 평균 오차·최대 오차·측정 실패율을 따로 기록한다. 터치 직후 촬영, 재촬영, 앱 복귀도 포함한다. AF/AE 안정화를 셔터의 필수 대기 조건으로 바꾸지 않는다.

검증 로그: `/private/tmp/dobby-camera66-core-full.log`, `/private/tmp/dobby-camera66-ui.log`, `/private/tmp/dobby-camera66-ui-retry.log`, `/private/tmp/dobby-camera66-native-release.log`, `/private/tmp/dobby-camera66-device-release.log`. 시뮬레이터 결과 번들: `/tmp/dobby-lidar-ui.aGkzu2/Results.xcresult`, `/private/tmp/dobby-camera66-ui-retry.xcresult`.

## 0.5×가 별도 작업인 이유

현재 공개 API로 ARKit 측정 경로의 초광각 0.5× 선택을 확정할 수 없다. Apple 엔지니어의 설명도 내부 카메라 사용과 개발자가 선택할 수 있는 카메라를 구분한다. 초광각 사진에 기존 Wide LiDAR 깊이를 그대로 붙이면 좌표와 관측 영역이 달라진다.

진짜 0.5×는 별도 AVFoundation 캡처 구조에서 RGB·깊이 동기화, 카메라 내부/외부 보정, 렌즈 왜곡, 가려짐을 처리하고 실기기에서 검증해야 한다. Wide LiDAR가 관측하지 못한 초광각 바깥 영역의 깊이는 정확한 측정값으로 만들 수 없다.

공식 참고 자료:

- [ARKit 카메라 설정과 향상된 캡처](https://developer.apple.com/videos/play/wwdc2022/10128/)
- [LiDAR Depth Camera 및 MultiCam](https://developer.apple.com/videos/play/wwdc2022/110429/)
- [Apple 엔지니어의 ARKit 초광각 설명](https://developer.apple.com/forums/thread/831657)
- [초점 위치 좌표 계약](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focuspointofinterest)
- [ARFrame displayTransform](https://developer.apple.com/documentation/arkit/arframe/displaytransform(for:viewportsize:))
- [카메라 사이 외부 보정 행렬](https://developer.apple.com/documentation/avfoundation/avcapturedevice/extrinsicmatrix(from:to:))
