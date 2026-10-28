# 실측 촬영의 일반 카메라·초광각 연속 미리보기

## 표시와 측정

최신 main `5fedf04`(#114)의 공용 카메라 UI 추출을 반영했다. 실측·상세 촬영은 `Shared/Camera`의 `CameraCaptureOptionsView`, `CameraExposureView`, `CameraAspectRatioView` 구현을 함께 사용한다. `DetailCaptureOptionsView`는 기존 모델을 공용 상태·콜백으로 연결하는 어댑터만 담당하며, 삭제된 Detail 노출·비율 뷰를 복제해 두지 않는다. 상세 촬영의 기본 UI를 유지하고 실측의 좁은 창·큰 글자·햅틱·표시선 모션은 같은 공용 컴포넌트의 표시 옵션으로 연결한다.

중앙 사진 창의 1x는 일반 카메라 전체 4:3 원본이다. 2x는 기존 `RegisteredCameraCrop`을 RGB·깊이·K에 한 번만 적용한다. 16:9·1:1 선택은 표시 크롭이다. 주변을 보이게 하기 위해 중앙 영상을 화면 전체로 확대하지 않는다.

한 `AVCaptureMultiCamSession`이 `builtInLiDARDepthCamera`의 일반 RGB·절대 깊이와 `builtInUltraWideCamera`의 RGB를 소유한다. ARSession을 병행 실행하지 않는다. 호환 인터페이스 이름 `ARKitCaptureProvider` 내부에서 소스를 선택한다. 미지원 시 MultiCam을 중지한 뒤 ARKit으로 순차 폴백하며, 새 sessionID로 이전 소스의 사진·Vision 콜백을 무효화한다.

## 프레임과 렌즈 정합

- `AVCaptureDataOutputSynchronizer`의 일반 RGB·LiDAR가 같은 콜백으로 온 실제 쌍을 유지한다. 초광각은 다른 콜백으로 도착할 수 있으므로 세션 동기화 시각을 기준으로 최대 3개씩만 보관해 연결한다. 전체 세 시각의 범위가 1/60초 이내인 가장 가까운 초광각만 사용하고, 드롭·누락·중복·오래된 세션 프레임은 사용하지 않는다. 서로 따로 온 일반 RGB와 깊이를 임의로 조합하지 않는다.
- 출력 회전·반전·전자식 손떨림 보정을 끈다. 일반 RGB의 기준 K는 동기화된 절대 깊이의 `cameraCalibrationData`에서 얻는다. 일반 영상의 별도 K attachment는 제공될 때만 교차 검증하며, 이 선택적 attachment가 없다는 이유로 정상적인 LiDAR 보정을 거부하지 않는다. 초광각은 짝이 되는 깊이 보정 정보가 없으므로 자체 프레임별 K와 기기의 기하 왜곡 보정을 계속 요구한다. 외부 행렬은 물리 일반 카메라 → 초광각에서 얻고 이동량을 mm에서 m로 변환한다.
- AVDepthData는 렌즈 왜곡을 포함한다. RGB와 깊이를 같은 factory forward LUT로 rectified destination → distorted source 역래스터화한다. 일반 영상 K가 제공되었지만 잘못됐거나 depth calibration K와 모순되면 계속 거부한다. 보정 정보·LUT 자체의 누락을 임의의 기본값으로 대체하지 않는다.
- 깊이의 confidence는 `nil`이다. 결측·비정상 깊이는 0으로 보존하고 구멍을 보간하지 않는다.
- 촬영 출처는 `avFoundationLiDAR`다. AR tracking 상태·이동속도를 만든 값으로 채우지 않는다. 후보 선택에는 `synchronizedCalibratedLiDAR` 증거를 별도로 기록한다. 모션 미확인 안정성 보너스와 준비된 측정 재사용을 허용하지 않는다.

## 연속 합성

`MultiCameraPreview`의 MTKView 하나에서 동기화된 두 영상을 그린다. 초당 10회 UIImage 재생성 방식은 제거했다. GPU 작업은 한 개만 진행하고 최신 프레임도 한 장만 보관한다. 렌더 준비·셰이더 컴파일·색 보정·GPU 제출은 UI 실행기 밖에서 수행한다. 방향·배율·영역·session 변경은 이전 GPU 결과의 표시를 막는다.

1. 일반 카메라 원본이 있으면 사진 창 밖이라도 그대로 사용한다. 비율·2x 때문에 생긴 여백을 불필요하게 초광각으로 교체하지 않는다.
2. 일반 카메라 범위 밖만 실제 초광각으로 채운다. 경계 안쪽 LiDAR의 3×3 지지점으로 국소 평면을 추정하고 불일치 점을 제거해 기울어진 바닥의 시차를 보정한다. 지지 깊이가 부족하면 회전만 보정한 실제 초광각으로 폴백한다. 이는 무한원 방향 정합이며 가까운 물체의 이동 시차를 보정했다고 주장하지 않는다. 미터 단위 깊이를 만들거나 측정 깊이를 변경하지 않는다.
3. 사진 창 바깥의 실제 겹침 영역에서만 렌즈 간 밝기·색 차이를 보정하고 경계를 페더링한다. 중앙 사진은 일반 카메라만 사용한다.
4. GPU는 주변을 임의로 어둡게 만들지 않는다. 전체 연속 영상 위에 SwiftUI `.glassEffect(.regular, in: Rectangle())` 한 장을 적용하고 사진 창을 even-odd 마스크로 비운다. 실제 글라스 판의 외곽은 화면 바깥으로 확장해 반사 테두리가 보이지 않게 하고, 재질의 불투명도를 낮춰 주변 영상을 가리지 않도록 한다. 중앙 사진은 재질 없이 선명하게 유지한다. 별도 영상을 늘려 붙이거나 경계 픽셀을 반복하지 않는다.
5. 촬영 후보로 선택된 정확한 wide·depth·ultra 패킷을 pin해 분석 중 주변부도 같은 시점에 정지한다. 측정 사진에는 초광각을 합성하지 않는다.

초점·노출 제스처와 윤곽은 중앙 창 안에만 존재한다. 사진·윤곽·초점은 같은 rectified normalized 센서 좌표를 공유한다. 하드웨어 초점 요청만 distorted 렌즈 좌표로 변환한다. 비율 변경 중 중앙 창과 합성 경계도 같은 CGRect를 보간한다.

사진 창은 새 `MeasurementCameraChromeLayout.photoViewport`가 배치한다. 세로 화면은 9:16 카메라 캔버스 안에서 선택한 비율을 유지하며 전체 너비를 우선한다. 402×874 기준 16:9는 y60·높이714.667, 4:3은 y127·높이536, 1:1은 y177.25·높이402다. 16:9 사진은 셔터 뒤까지 이어진다. 4:3의 전체 1x 구도는 유지하며 raw RGB·깊이·K를 변경하지 않는다. 가로 화면은 기존 우측 조작 영역 배치를 유지한다.

배율 버튼은 사진 하단에서 40pt 위를 따라 움직이고 고정 셔터 영역 앞에서 제한한다. 안내는 그 위에 배치하며 큰 글꼴은 실제 텍스트 높이를 반영한다. 셔터의 기본 위치를 올리고, 현재 선택된 비율 하나만이 아니라 모든 지원 비율의 사진 테두리와 92pt 셔터 원 사이에 여유가 있는 공통 위치를 계산한다. 셔터·더보기 위치는 사진 비율과 독립적으로 고정한다. 글라스 마스크·사진·배율 위치는 같은 비율 변경 애니메이션으로 갱신한다.

## 실행 조건과 실패

실제 기기의 지원 카메라 조합, 전체 4:3 화각, 30fps video/depth 포맷, K, 절대 깊이, 공장 보정 정보를 실행 시 검사한다. commitConfiguration 이후 hardwareCost와 systemPressureCost가 모두 1 이하인 포맷을 선택한다. 미지원 조합은 ARKit 단일 카메라로 폴백하며 주변을 가짜 영상으로 채우지 않는다.

일반 카메라는 저해상도 전체 화각 후보를 우선하되, 2560px의 고정 상한으로 필요한 포맷을 제거하지 않도록 4096px까지의 후보를 허용한다. 따라서 4032×3024도 MultiCam·30fps·4:3·절대 깊이·보정 조건과 실제 하드웨어 예산을 만족할 때만 실행할 수 있다. 전체 native 1x 화각 조건은 완화하지 않는다. 표시 전용 초광각에는 일반 카메라와 동일한 최고 화각 0.25° 조건을 적용하지 않고, 실제 보정 화각이 넓은 유효 후보부터 예산에 맞게 시도한다. 초광각의 실제 K로 해당 영상을 투영하며 측정용 RGB·깊이를 대체하지 않는다.

시작 완료는 세션의 isRunning만으로 판단하지 않는다. 첫 동기화·캘리브레이션 검증 패킷까지 확인한다. 그 전의 실패·시간 초과는 시작 실패로 반환해 세션을 완전히 중지한 뒤 ARKit으로 폴백한다. 이미 시작이 완료된 뒤 발생한 열·중단 오류는 런타임 실패로 구분한다. 취소된 시작 호출이 정리되기 전에 새 시작이 조용히 반환하지 않도록 준비 소유권도 직렬화한다.

열 상태가 serious면 지원하는 경우에만 일반·초광각·깊이 주기를 함께 15fps로 낮춘다. critical, 중단, 유효 패킷 장기 미수신은 구체적 실패로 중지한다. 이전 중지·시작·취소 콜백은 새 세션을 변경할 수 없다.

## 2026-10-28 실기기 주변부 미표시 진단

실제 iPhone 화면에서 **ARKit 기본 미리보기로 전환했다는 폴백 안내가 표시된 것**을 확인했다. 기존 폴백 경로의 주변부는 `Color.black`이므로, 이 상태에서는 글라스 투명도만 바꿔도 실제 초광각 영상이 나타나지 않는다. 최초 설치본의 정확한 시작 실패 사유는 안내에 노출되지 않았고 로그도 확보되지 않았다. 사용자가 수정본을 Xcode에서 다시 실행한 뒤 12:03 화면을 확인하자 `unsupportedFormats` 사유가 표시됐다. 따라서 당시 실패 단계는 포맷 선택이며, 어느 카메라의 어떤 제외 조건이었는지는 추가 진단 전까지 확정하지 않는다.

기존의 일반 안내는 버튼이 아니며, 카메라 터치를 가로채지 않도록 비상호작용 뷰로 구현되어 있다. 이제 실제 `surroundingsUnavailableReason`도 화면에 함께 표시하고, 모든 시작 실패 원인은 `com.dobby.camera` / `LiDARMultiCam`의 error 로그로 기록한다. 이미지·깊이 원본이나 비밀 키는 기록하지 않는다.

코드에서는 정상 지원 포맷을 불필요하게 제외할 수 있는 2560px 상한과 표시 전용 초광각의 최고 화각 제한을 수정했다. 또한 Apple의 동기화 LiDAR 예제처럼 일반 RGB의 K는 짝이 맞는 depth calibration에서 얻도록 하고, 일반 영상 K attachment는 선택적 검증으로 분리했다. 실제 cm 계산에 필요한 절대 깊이, 공장 K/LUT, 시간 정합 및 일반 1x 화각 조건은 유지한다.

포맷 실패 확인 후, 표시 전용 초광각에만 적용하던 불필요한 4:3 조건도 제거했다. 초광각은 16:9 등 실제 래스터 크기와 자체 K를 사용하며 일반·LiDAR의 4:3 조건과 분리한다. 두 비율의 독립 렌즈/래스터를 사용하는 GPU 테스트로 주변 투영과 중앙 일반 영상 보존을 검증했다. 실패 시 카메라별 포맷 제외 수, 영상 픽셀 형식, 실제 1x 배율 지원을 구분해 표시한다.

12:11 기기 화면과 실행 중 Xcode 로그에서는 포맷 선택이 통과하고 동기화 패킷 대기에서 실패한 것을 확인했다. 선택 포맷은 일반 1920×1440·화각 72.044113°(native 기준과 동일), 초광각 1280×720·보정 화각 106.200699°, 깊이 320×240·30fps, hardwareCost 0.5·pressureCost 0.313507이었다. 따라서 이 실행의 원인을 포맷 부재나 하드웨어 비용 초과로 설명할 수 없다. 세 출력이 같은 콜백에 있어야만 통과시키던 조건을 제거하고, SDK가 허용하는 부분 콜백을 위의 제한된 시간 조합기로 연결했다. 수신·드롭·연결 활성 상태도 원인에 구분해 기록한다. 새 조합기 실행 결과가 나오기 전까지 실제 수신 실패의 최종 원인은 확정하지 않는다.

부분 콜백 연결 수정본을 사용자가 아이폰에서 직접 다시 실행한 뒤 **“잘 된다”**고 주변부 정상 동작을 확인했다. 이는 사용자의 실제 기기 확인이며, 자동 테스트와 별도로 기록한다. 후속 화면 캡처 시 기기는 잠금 화면이어서 작업자가 정상 카메라 화면을 추가로 관찰한 증거는 없다. 물리 길이 오차, 지속 프레임 속도, 모든 비율·장면에서의 경계 품질까지 검증했다고 해석하지 않는다. 다시 폴백하면 화면에 표시된 구체적인 사유로 원인을 구분한다.

## 검증 범위

자동 테스트는 생성된 픽셀·깊이·K·외부 행렬을 사용한다. LUT 방향, RGB/depth 좌표, 결측, 1x/2x·비율·4방향 초점 역변환, 실제 runtime Metal 컴파일 및 GPU 픽셀, 중앙 영상 불변, 초광각 주변, 기울어진 평면, 깊이 부족 예외를 검증한다. 기존 노출·UI·등록 크롭 회귀 테스트도 실행한다.

2026-10-28 검증: main `7a83f56` 반영 후 코어 71개, 카메라 표현·보정·시작 수명 단위 54개, UI 10개로 중복 제외 135개가 통과했다. UI 중 메뉴·비율·분석/결과 연결 2개는 main 반영 후 다시 통과했다. 최종 iPhone 대상 앱·QuickCopyWidget 빌드도 서명 없이 통과했다. 로그는 `/private/tmp/dobby105-multicam-core.log`, `/private/tmp/dobby105-multicam-main-final.log`, `/private/tmp/dobby105-multicam-startup-final.log`, `/private/tmp/dobby105-multicam-flow.log`, `/private/tmp/dobby105-multicam-delivery-device.log`에 있다. 물리 iPhone 설치·실행은 하지 않았다.

Regular Glass·반응형 배치 후속 검증(2026-10-28): 사진/배율 기하 66개, 글라스 마스크·GPU·애니메이션 단위 16개, UI 7개로 총 89개가 통과했다. 비율별 배율 이동과 셔터/더보기 고정, 전체 너비 16:9, 중앙 픽셀·초점·2x·분석/결과·회전 보존을 확인했다. 1:1·16:9·4:3 스크린샷도 직접 검토했다. 로그는 `/private/tmp/dobby105-regular-glass-core.log`, `/private/tmp/dobby105-regular-glass-ui.log`, `/private/tmp/dobby105-regular-glass-device.log`; 결과 번들은 `/private/tmp/dobby105-regular-glass-ui.xcresult`다. 이는 합성 UI·생성된 GPU 픽셀 검증이며 실제 iPhone 광학 성능 검증과 구분한다.

주변부 폴백·매트 재질·셔터 간격 후속 검증(2026-10-28): 기하 코어 54개, 글라스 마스크 5개, UI 7개, 시작/포맷 16개, RGB·깊이 보정 14개로 중복 제외 96개가 통과했다. 402×874에서 고정 셔터 중심은 762pt에서 718pt로 올라갔다. 모든 지원 비율의 실제 사진 테두리와 셔터 원 사이의 간격을 검사하고, 1:1·16:9·4:3 스크린샷을 확인했다. Regular Glass의 실제 외곽을 화면 밖으로 96pt 확장하고 불투명도 0.42를 적용해 반사 테두리 대신 내부 재질만 보이도록 했다. 투명도 줄이기 설정은 유지한다. 최종 앱·위젯의 iPhone 대상 무서명 빌드도 통과했다. 로그는 `/private/tmp/dobby105-matte-shutter-core.log`, `/private/tmp/dobby105-matte-shutter-ui.log`, `/private/tmp/dobby105-periphery-committed-graph.log`, `/private/tmp/dobby105-periphery-committed-graph-device.log`다. 물리 기기의 새 빌드 실행 확인은 별도로 남아 있다.

초광각 비율 분리 후속 검증: 시작·포맷 테스트는 19개로 늘었고, 기존 GPU 합성 11개와 서로 다른 래스터 회귀 1개가 통과해 위 범위와 합쳐 중복 제외 111개를 확인했다. 관련 로그는 `/private/tmp/dobby105-peripheral-format-selection.log`, `/private/tmp/dobby105-ultra-independent-raster.log`, `/private/tmp/dobby105-peripheral-format-selection-device.log`다. 마지막 로그는 최종 앱·위젯의 iPhone 대상 무서명 빌드 통과를 기록한다. 이 단계 역시 새 물리 기기의 MultiCam 실행 성공과 구분한다.

부분 콜백 후속 검증: 시작·진단 테스트 21개와 RGB·깊이 보정 14개가 `/private/tmp/dobby105-partial-packet-join-final.log`에서 통과했다. 순서·위상 차이·1/60초 경계·이전 세션·중복·버퍼 상한·동일 콜백 최신 초광각 선택을 다룬 새 Core 테스트 12개도 `/private/tmp/dobby-timestamp-join-tests`에서 통과했다. 이전 범위와 합쳐 중복 제외 125개다. 최종 iPhone 대상 앱·위젯 무서명 빌드 로그는 `/private/tmp/dobby105-partial-packet-join-final-device.log`다.

이 결과가 실제 iPhone의 지원 조합, 지속 프레임 속도, 물리 실측 정확도, 기본 카메라와 완벽히 같은 광학 경계를 입증하지는 않는다. 떨어진 두 렌즈는 가림·깊이 불연속·반사·노출 차이 때문에 모든 장면에서 완벽히 이어질 수 없다. LUT가 가리키는 원본 위치가 바깥이면 중앙 사진은 보정 결과와 동일하게 결측으로 남기며 초광각으로 대체하지 않는다.

실기기 비교는 같은 위치에서 1x·2x, 4:3·16:9·1:1, 회전, 가까운 옷/바닥 경계, 탭 초점/EV, 촬영/분석/재촬영, 열 상태를 확인해야 한다. 기기 설치·실행 여부는 자동 테스트 결과와 별도로 보고한다.

## Apple 근거

- [WWDC22: LiDAR Depth Camera와 Ultra Wide의 MultiCam 사용](https://developer.apple.com/videos/play/wwdc2022/110429/)
- [AVCaptureMultiCamSession](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession)
- [Apple: 동기화된 LiDAR 영상·깊이와 cameraCalibrationData 사용](https://developer.apple.com/documentation/avfoundation/capturing-depth-using-the-lidar-camera)
- [프레임 밖 보기](https://support.apple.com/guide/iphone/change-advanced-camera-settings-iphb362b394e/ios)
- 로컬 SDK의 `AVCameraCalibrationData.h` LUT 역래스터화 예제, `AVDepthData.h`의 nonrectilinear 깊이 계약, `AVCaptureDevice.h`의 외부 행렬 mm 단위·안정화 제한도 확인했다.
