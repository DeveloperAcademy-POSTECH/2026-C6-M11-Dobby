#!/bin/bash
# Created by mason on 10/21/26.
# macOS 순수 백엔드 검증 전용. AVFoundation 실기기·UI 검증을 대체하지 않는다.
# 실행: bash Tools/run-camera-backend-tests.sh [swift test 옵션]
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/dobby-camera-backend.XXXXXX)"
mkdir "$test_dir/Sources" "$test_dir/Tests"
cp "$repo_dir/Tools/CameraBackendTests/Package.swift" "$test_dir/Package.swift"
camera_dir="$repo_dir/Dobby/Dobby/Features/Camera"
for source in \
  Integration/CapturedAsset.swift Models/CameraFailure.swift \
  Models/DetailCameraOptions.swift Capture/DetailCameraControl.swift \
  Capture/DetailExposureCompletion.swift Capture/DetailPhotoCropGeometry.swift \
  Capture/DetailPhotoProcessor.swift Storage/CameraPhotoStore.swift; do
  ln -s "$camera_dir/$source" "$test_dir/Sources/$(basename "$source")"
done
for suite in DetailCameraOptions DetailCameraOptionsRegression DetailExposureControl \
  DetailPhotoCropGeometry DetailPhotoProcessor; do
  ln -s "$repo_dir/Tests/DobbyPresentationTests/${suite}Tests.swift" "$test_dir/Tests/"
done
# 실패 시에도 결과와 구성 파일을 보존하며 기존 저장소/프로젝트 설정을 수정하지 않는다.
printf 'Backend test artifacts: %s\n' "$test_dir"
swift test --package-path "$test_dir" "$@"
