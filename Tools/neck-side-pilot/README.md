# Luna 대상 의류의 로컬 목옆점 모델

`model-test`의 기본 실측에서 Luna v4가 나머지 랜드마크를 찾고, 번들 `NeckSidePilot.mlpackage`가 좌우 목옆점을 보완합니다. 대상은 기존 분류 정책의 Blazer, Jacket, Coat, Denim Jacket, Sports Jacket, Hoodie, Sweater, Polo입니다. 다른 상의와 하의, 사진 A/B/C 비교 실험은 바꾸지 않습니다.

## 입력과 채택

- 방향 검증과 의류 마스크 생성 후 Luna와 같은 여백 포함 의류 크롭을 입력합니다.
- Vision `.scaleFill`: RGB 256×448, letterbox 없이 리사이즈합니다. 모델 안에서 1/255와 채널별 ImageNet 정규화를 한 번씩 적용합니다.
- 출력 `heatmaps` `[1, 2, 112, 64]`: image-left, image-right 순서입니다. 가장 큰 logit 주변 5×5의 local soft argmax로 디코딩합니다. 착용자 기준 좌우가 아닙니다.
- 좌표는 크롭 → 전체 정렬 사진 → 원본 RGB/깊이 순서로 복원합니다. 기존 마스크 근거리 보정과 배치 검증을 통과한 두 점을 함께 채택합니다. 점수나 가려짐 신뢰도는 만들어 넣지 않습니다.
- 실패 시 첫 Luna 목옆점을 유지합니다. 이 로컬 경로에서는 기존 목·어깨 확대 및 좌우 개별 확대 3회는 요청하지 않습니다.
- 총장은 기존 `neck_left → top_length_hem` 마스크/깊이 계산을 유지합니다. 새 모델은 총장 밑점을 예측하지 않습니다.

## 파일과 기록

- 모델: `Dobby/Dobby/LiDAR/Models/NeckSidePilot.mlpackage` (약13MiB, Float32)
- 버전: `neck-side-resnet18-pilot-v1-epoch44`
- 가중치 원본 SHA256: `d019dc075f867e572be0c91a8d0265e68953e614334830c9e7c0d269bb0cea96`
- 저장 기록의 `localNeckLandmarks`: 버전, 입력 크롭, 전체 정렬 사진 기준 원본 예측 좌표, 채택 ID, 실패 코드.
- Luna 원본은 `remoteGarmentCrop.localResponse`에 유지합니다. 계산에 반영한 포인트는 기존 `rawPoints`/`automaticAdjustments`로 구분합니다.
- 모델은 Xcode 폴더 동기화 빌드에 포함됩니다. 앱 재빌드만 필요하며 Worker 추가 배포나 새 목점 전용 API 키는 필요하지 않습니다. 나머지 Luna 점에는 기존 인증/서버가 필요합니다.

## 학습과 검증 범위

사용자가 좌우 목옆점을 표시한 사진 72장(48 학습, 13 검증, 11 테스트)으로 ImageNet ResNet18 layer1–3와 skip decoder를 미세조정했습니다. 최대100회 중69회 조기 종료, 검증 기반44회 checkpoint입니다. 검수 완료 플래그는 미완료였으며, 유사 의류는 보수적인 시각 그룹으로 같은 분할에 뒀습니다. 실제 의류 ID가 검증된 완전한 개체 분할은 아닙니다.

테스트 11장/22점에서 원본 평균8.9px, 10px 이내59.1%입니다. 동일 촬영 배경이며 실제 Dobby 사진·가려짐·cm 오차를 검증한 수치가 아닙니다. 학습은 회전된 전체 사진을 사용했고 앱은 의류 크롭을 사용하므로 입력 분포 차이도 실제 촬영으로 확인해야 합니다. 이 모델은 두 점을 항상 예측하며 자체적인 신뢰도/지원불가 판단기는 없습니다.

Core ML Float32 변환 후 검증·테스트24장으로 native Core ML과 PyTorch 좌표를 비교했고, 최대 원본 좌표 이동은0.0001px 미만이었습니다. 이는 변환 일치 검증이며 랜드마크 정답 정확도 보증은 아닙니다. iOS 테스트는 번들 모델의 Vision 추론, 네 방향 크롭 복원, 비대상 종류 제외, 실패/마스크 탈락 시 Luna 원본 유지, 다른 포인트 유지까지 확인합니다.

## 변환 재현

학습 작업 폴더의 `training/train.py`와 `training/pilot-v1/best.pt`가 필요합니다. 팀원의 앱 실행에는 이 학습 폴더나 Python이 필요하지 않습니다.

```sh
python export_coreml.py --training-dir /path/to/jacket-neck-training/training \
  --output /path/to/NeckSidePilot.mlpackage --report /tmp/neck-parity.json
```

변환 환경: Python3.13, coremltools9.0, torch2.7.1, torchvision0.22.1, Pillow. 네트워크 입력 형식은 [Apple 공식 ImageType 문서](https://apple.github.io/coremltools/docs-guides/source/image-inputs.html)를 참고했습니다.
