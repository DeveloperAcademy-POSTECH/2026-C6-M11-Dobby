# 카메라·의류 ML 연동 계약

## 파일 경계

- `LiDAR/Core`: 프레임·측정점·결과 계약, 거리 엔진, 좌표 회전, 저장·재생, 비동기 측정 파이프라인.
- `LiDAR/Capture/ARKitCaptureProvider.swift`: 현재 직접 테스트를 위한 ARKit 캡처 어댑터. 카메라 세션을 소유한다.
- `LiDAR/UI`: 직접 테스트 화면. 실제 상품 등록 흐름에서도 같은 엔진을 호출할 수 있다.
- `Package.swift`: Core를 독립적으로 테스트하기 위한 구성. 앱은 해당 소스를 Xcode의 동기화 그룹으로 직접 컴파일한다.

## 메이슨: 카메라 입력

`CaptureSnapshotProviding.capture(orientation:)`가 `CaptureSnapshot`을 반환한다. 현재 ARKit 어댑터를 교체할 때 캡처를 소유하는 세션은 하나로 유지한다.

필수 계약:

1. `frame.sessionID`는 캡처 세션마다 새 UUID, `frame.frameID`는 촬영마다 새 UUID.
2. JPEG는 회전하지 않은 원본 RGB 이미지. `imageSize`는 JPEG의 실제 픽셀 크기.
3. 깊이는 **미터 단위 광축 깊이**이며 전체 RGB 이미지와 같은 화각으로 정합된 직선 투영 좌표여야 한다.
4. `intrinsics.referenceSize`는 `imageSize`와 같아야 한다. 잘못된 크기를 엔진이 추측해서 보정하지 않는다.
5. 깊이맵과 RGB는 같은 종횡비여야 한다. 다른 카메라·크롭·왜곡의 변환은 캡처 어댑터에서 먼저 해결한다.
6. 깊이는 행 패딩을 제거한 연속 배열. 비정상·없는 깊이는 0. 신뢰도 배열은 0/1/2, 없으면 nil.
7. 원본과 깊이·보정값은 같은 프레임에서 얻는다. 사진만 새로 촬영한 뒤 이전 깊이를 사용하지 않는다.
8. 스냅샷은 불변 값으로 전달한다. 엔진은 카메라 버퍼를 직접 보관하지 않는다.

현재 ARKit 구현의 기본 측정은 raw `sceneDepth`다. 지원 시 같은 ARFrame의 `smoothedSceneDepth`를 비교용으로 함께 저장한다. AVFoundation 경로를 추가한다면 실제 출처를 기록한다. AVFoundation 깊이를 넣으려면 미터/상대 깊이 구분, 보정·왜곡·시간 정합을 어댑터에서 검증해야 한다. 초광각 좌표를 광각 LiDAR에 단순 배율로 연결하지 않는다.

## 이치: 측정점 출력

`GarmentLandmarkProviding`를 구현한다.

```swift
protocol GarmentLandmarkProviding: Sendable {
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet
}
```

구현체는 `snapshot.imageJPEG`로 추론하고 resize·padding·crop·rotation을 되돌린 뒤, 원본 좌표의 점과 같은 sessionID/frameID를 반환한다.

좌표는 왼쪽 위 원점, +x 오른쪽, +y 아래, 범위 `[0, 1)`이다. 원본 픽셀 좌표는 `x × imageWidth`, `y × imageHeight`다. 깊이 픽셀의 표본 중심은 `(index + 0.5)` 규약을 사용한다. 화면의 aspect-fill 좌표를 직접 넘기지 않는다.

측정점은 의미 ID로 전달한다. `MeasurementDefinition.longSleeve`의 초기 ID는 다음과 같다.

| 항목 | 점 연결 |
|---|---|
| 가슴 | `armpitLeft` → `armpitRight` |
| 어깨 | `shoulderLeft` → `shoulderRight` |
| 총장 | `neckSide` → `hemBelowNeck` |
| 소매 | `shoulderLeft` → `cuffLeft` |

위 상의 계약의 좌우 기준은 학습 라벨과 팀 측정 기준을 확정해야 한다. 새 bottom7 하의 모델의 좌우는 제공 스키마대로 **정방향 이미지 기준**이며 착용자 기준으로 바꾸지 않는다. 임의 점 배열 순서에 의존하지 않는다. 모델 점수는 `confidence`에, 가림은 `isVisible`에 전달한다. origin은 `.model`, 실제 모델 버전도 기록한다. 수동점은 `.manual`이고 모델 신뢰도로 위장하지 않는다.

마스크는 선택 사항이며 원본 전체 이미지와 정합된 0/1 배열을 제공한다. 크롭된 모델 마스크를 그대로 보내지 않는다.

## 호출 예

```swift
let snapshot = try await camera.capture(orientation: orientation)
let result = try await MeasurementPipeline().measure(
    snapshot: snapshot,
    provider: modelAdapter,
    definitions: MeasurementDefinition.longSleeve
)
```

이미 점을 가지고 있다면 아래처럼 직접 호출한다. 계산은 MainActor 밖의 actor에서 진행된다.

```swift
let result = await MeasurementPipeline().measure(
    snapshot: snapshot,
    landmarks: landmarkSet,
    definitions: MeasurementDefinition.longSleeve,
    options: MeasurementOptions()
)
```

`result.values`에는 요청한 모든 항목이 포함된다. 각 항목의 `status`, `failure`, `meters`를 확인한다. `meters == nil`을 0cm로 바꾸지 않는다. 한 항목이 실패해도 다른 유효 항목은 남는다.

점의 3D 좌표는 +x 오른쪽, +y 아래, +z 전방인 광학 좌표계다. ARKit 월드 좌표와 합치려면 별도 축 변환과 카메라 자세가 필요하다. 현재 엔진은 한 프레임의 거리만 계산하며 프레임 사이 점군을 자동 융합하지 않는다.

## 품질 정책

기본 표본 반경은 깊이 픽셀 3, 최소 표본은 6개, 깊이 유효 범위는 0.15~3m다. 이는 제품 정확도 지원 범위 보장이 아니라 현재 필터의 설정이다. 실측 결과에 따라 `MeasurementOptions`를 조정한다.

깊이 표면을 분리하고 이상치를 제거한 다음 국소 평면의 역깊이를 맞춘다. 공간적으로 충분한 표본과 작은 잔차가 있을 때 원래 측정점의 깊이를 추정한다. 그렇지 않으면 가까운 표본의 중앙값으로 대체하고 `uncertain`으로 반환하거나 깊이 부족으로 실패한다.

센서 신뢰도 미상/중간, 여러 깊이 표면 혼재, 모델 점수 누락도 `uncertain`으로 남긴다. 품질 등급과 모델 점수는 cm 오차의 확률 보증이 아니다.

## 확장 시 주의점

- 점을 안쪽으로 이동시켜 안정화하면 실제 길이가 짧아진다. 샘플 영역과 측정점 위치를 구분한다.
- 임의의 다른 프레임 깊이를 대입하지 않는다.
- 2D 중점과 실제 3D 중점은 기울기에서 다르다. 필요한 정의에 맞는 점을 제공한다.
- 여러 구간을 지정하면 명시한 3D 직선 구간의 합이다. 천의 표면 경로를 자동 복원한 것으로 표시하지 않는다.
- 팀의 실제 카메라/ML 모델을 붙인 후 실물 검증을 수행한다. 현재 테스트 화면의 수동점 결과와 비교하면 오차의 출처를 분리할 수 있다.


## 촬영 중 실시간 준비 상태

`LiveForegroundAnalyzer` → `LiveCaptureEvidence` → `LiveReadinessEvaluator` → `ARKitCaptureProvider.liveReadiness` → 카메라 테두리·안내 카드 순서로 연결된다. 측정용 스냅샷·측정점 계약과 분리되어 있으며, 이 안내만으로 최종 치수를 확정하지 않는다.

### 메이슨: 영상·깊이와 화면 좌표

- 같은 ARFrame의 RGB와 raw sceneDepth를 사용한다. Vision 작업은 별도 직렬 큐에서 최대 512px 영상으로 실행한다.
- 기본 최소 분석 간격은 0.6초다. 동시에 하나만 처리하며 대기 프레임을 쌓지 않는다. RGB 버퍼는 최대 한 장만 보관하고 ARFrame 자체는 보관하지 않는다.
- 마스크는 원본 RGB 전체와 같은 종횡비이며 0/1 배열, bounds는 왼쪽 위 원점 정규화 좌표다. 크롭된 화면 좌표를 넣지 않는다.
- 화면 테두리는 `ARFrame.displayTransform(for:viewportSize:)`로 회전과 aspect-fill 크롭을 반영한다.
- 분석 결과가 2초 이상 오래되거나 카메라 프레임이 끊기면 성공 표시를 해제한다. 세션 교체·중단 결과는 폐기한다.
- ARKit 추적 상태뿐 아니라 분석 프레임 사이의 이동 속도와 회전 속도로 움직임을 확인한다. 초기 기준은 0.10m/s, 12도/s 미만이며 실물 검증 후 조정한다.

### 이치: 전경을 의류 모델로 교체

현재 전경 마스크는 의류 전용 모델 출력이 아니다. 의류 모델을 연결할 때는 같은 프레임의 의류 후보 개수·전체 이미지 마스크·정규화 bounds를 `LiveCaptureEvidence`에 제공한다. 모델의 resize/padding/crop/rotation을 되돌려야 한다. `candidateCount`는 단순 전경 개수에서 실제 의류 후보 개수로 교체할 수 있다.

현재 `LiveForegroundAnalyzer`의 `analyze`가 이 역할을 한다. 카메라 어댑터와 평가기는 유지하고 분석기 구현을 교체하면 된다. 학습 모델의 의류 판별과 측정점 품질 조건은 별도로 연결한 뒤 성공 문구를 바꾼다. 지금의 녹색 표시는 **대상 깊이 확보**까지만 뜻한다.

### 초기 판정 기준

| 조건 | 초기값 |
|---|---|
| 후보 개수 | 1개 |
| 마스크 면적 | 전체 이미지의 6% 이상 |
| 이미지 가장자리 여유 | 각 변에서 2% 이상 |
| 유효 깊이 | 후보 영역의 85% 이상, 0.15~3.0m |
| 높은 센서 신뢰도의 유효 깊이 | 후보 영역의 60% 이상 |
| 경계의 중간 이상 신뢰도 유효 깊이 | 경계 표본의 70% 이상 |
| 시간 안정성 | 2개 이상의 관측, 최소 0.35초 |
| 연속 후보 변화 | 사각형 IoU 0.8 이상, 중심 이동 0.025 이하, 중앙 깊이 변화 4cm 이하 |

설정은 `LiveReadinessConfiguration`에 모여 있다. 위 수치는 초기 UX 판정값이며 센서 정밀도나 ML 정확도 검증 결과가 아니다. 기울어진 옷의 깊이는 위치에 따라 달라지므로 전체 깊이 분산만으로 거절하지 않는다. 촬영 버튼을 이 상태로 강제로 잠그지 않는다.

Apple API 참고: [일반 전경 마스크 요청](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest), [ARKit 깊이 데이터](https://developer.apple.com/documentation/arkit/ardepthdata).

## 촬영 프레임 선택·깊이 출처 비교 (9/27)

- `CaptureSnapshot.frame`은 기본 측정용 raw 깊이를 유지한다. 선택 필드 `smoothedFrame`은 같은 프레임의 평활화 깊이, `selectionSummary`는 후보 수·선택 대기시간·선택 품질·정책 버전을 담는다. 기존 버전 1 JSON에 이 필드가 없으면 nil로 읽는다.
- 프레임 선택은 첫 사용 가능한 후보부터 0.35초 동안 진행하고 전체 요청 제한은 4초다. AR 추적이 정상이고 기존 움직임 기준(0.10m/s·12도/s 미만)을 충족하며 유효 깊이 표본이 있는 후보를 비교한다. 움직임을 아직 계산할 수 없는 후보는 미상으로 기록한다.
- 선택 점수는 전체 깊이 유효 비율 55%, 높은 신뢰도 비율 35%, 움직임 안정성 10%의 초기 우선순위다. **의류 마스크별 품질이나 cm 정확도 점수가 아니다.** 실측으로 검증한 값이 아닌 촬영 정책이며 실제 iPhone 17 Pro에서 지연·발열·거절률을 확인해야 한다.
- 현재 최선 후보의 RGB 복사본·깊이·보정 정보만 유지한다. ARFrame 자체나 모든 후보 영상을 쌓지 않으며 JPEG는 선택을 끝낸 뒤 한 번 생성한다. 새 후보로 교체하는 순간에는 이전·새 복사본이 잠시 함께 존재할 수 있다.
- 셔터 당시 ARFrame timestamp보다 나중인 프레임만 후보로 받는다. 큐에 남은 셔터 이전 프레임은 제외하고 AR 시각과 시스템 uptime의 원점을 비교하지 않는다.
- 취소·중단·세션 변경·시간 제한은 해당 요청 ID에만 적용한다. 늦게 실행된 타이머가 다음 촬영을 완료시키지 않는다.
- `smoothedFrame`은 기본 프레임과 sessionID, frameID, timestamp, capturedAt, imageSize, intrinsics, orientation이 같아야 한다. 출처는 각각 sceneDepth/smoothedSceneDepth이며, 버퍼 구조가 올바라야 비교 쌍으로 인정한다. 잘못된 비교 자료가 있어도 원본 기록의 계산은 보존한다.
- 같은 ARFrame에서 받은 평활화 깊이도 ARKit 내부에서는 과거 프레임을 사용한다. 동일 시점 출력의 비교라는 뜻이며, 독립적인 순간 측정 두 개를 얻었다는 뜻은 아니다. [Apple smoothedSceneDepth](https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth)
- 모델 점을 수동으로 수정하기 시작하면 미확인 모델 점은 다시 지정하도록 한다. 점 하나의 수정으로 다른 모델 점의 신뢰도 검사를 해제하지 않는다.

저장 시 두 JSON을 임시 폴더에 쓴 뒤 완성된 폴더를 공개한다. 기록 ID는 불변이며 편집 저장에는 새 ID를 사용한다. 기존 ID를 덮어쓰지 않고, 저장 완료 요약이 없는 이전 불완전 기록은 보고서에서 읽기/형식 오류로 집계한다.

## 자동 workflow와 인수 보고서

`AutomaticMeasurementWorkflow`가 공통 CaptureSnapshotProviding과 GarmentLandmarkProviding을 연결한다. `expectedLandmarkOrigin: .model`을 지정한 실제 경로는 합성 프레임·잘못된 점 출처·모델 버전 누락을 거절한다. 성공 시 모든 항목과 동일 snapshot/landmarks/options를 반환하고, 실패 시 단계와 원인을 보존한다.

workflow를 유지해 취소에 비협조적인 작업도 최대 2개로 제한한다. 시도 기록과 보고서의 목적별 분모, 다중 항목 줄자값과 실측 인수 항목은 [인수·연결 안내](LiDAR-Handoff.md)를 따른다. 자동점 재계산은 현재 엔진에 저장된 점을 넣는 것이며, 새 모델로 재추론한 정확도 평가가 아니다.

## MV 화면 연결 (9/28)

`RecordedMeasurementService`가 위 workflow와 `MeasurementAttemptJournal`을 묶어 실행 결과와 기록 오류를 반환한다. 화면 전환·진행 문구·알림은 View가 관리하며 서비스에는 저장하지 않는다. 자동 결과는 `AutomaticMeasurement`, 수동 편집은 `ManualMeasurement` 값 모델로 전달한다. `MeasurementDetailView(model:archive:)`에는 `ManualMeasurement`를 전달한다.

카메라/ML provider 계약과 `LiDARLabView(landmarkProvider:)` 주입 지점은 유지한다. 카메라 어댑터의 표시 문자열 `guidance`는 `CaptureState`·`CaptureFrameStatus`로 바뀌었으며 화면에서 표시 문구로 변환한다. 세부 책임은 [MV 구조](LiDAR-Architecture.md)를 따른다.


## 제공 하의 모델 연결 (9/28)

`CoreMLBottomLandmarkProvider`가 기본 실제 자동 촬영에 연결된다. 하의의 측정 정의는 `provider.schema.measurementDefinitions`로 생성하며 상의나 수동 바지 프리셋 ID를 혼용하지 않는다. `LiDARLabView(landmarkProvider:)`로 다른 공급자를 주입하는 기존 상의 경로도 유지한다. 모델 입력 형식, 좌표 복원, 대상 범위와 실측 한계는 [하의 인식 모델 안내](Bottom-Recognition.md)를 참고한다. 새 모델은 마스크를 출력하지 않으며 현재 실시간 전경 분석기를 대체하지 않는다.
