#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/dobby-lidar-ui.XXXXXX)"
test_destination="${1:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4}"
python3 - "$repo_dir" "$test_dir" <<'PY'
import json, pathlib, sys
repo, output = map(pathlib.Path, sys.argv[1:])
settings = {"SWIFT_VERSION":"5.0", "IPHONEOS_DEPLOYMENT_TARGET":"26.4", "CODE_SIGNING_ALLOWED":"NO", "SWIFT_DEFAULT_ACTOR_ISOLATION":"MainActor", "SWIFT_APPROACHABLE_CONCURRENCY":"YES", "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY":"YES"}
spec = {"name":"DobbyValidation", "options":{"deploymentTarget":{"iOS":"26.4"}}, "settings":{"base":settings}, "targets":{
"Dobby":{"type":"application", "platform":"iOS", "sources":[str(repo/'Dobby/Dobby')], "settings":{"base":{"PRODUCT_BUNDLE_IDENTIFIER":"com.dobby.Dobby", "GENERATE_INFOPLIST_FILE":"YES", "INFOPLIST_KEY_NSCameraUsageDescription":"옷 사진과 깊이로 길이를 측정합니다.", "INFOPLIST_KEY_UILaunchScreen_Generation":"YES", "INFOPLIST_KEY_UIApplicationSceneManifest_Generation":"YES", "INFOPLIST_KEY_UISupportedInterfaceOrientations":"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight", "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad":"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight", "TARGETED_DEVICE_FAMILY":"1,2"}}},
"DobbyUITests":{"type":"bundle.ui-testing", "platform":"iOS", "sources":[str(repo/'Tests/DobbyUITests')], "dependencies":[{"target":"Dobby"}], "settings":{"base":{"PRODUCT_BUNDLE_IDENTIFIER":"com.dobby.Dobby.UITests", "GENERATE_INFOPLIST_FILE":"YES", "TEST_TARGET_NAME":"Dobby"}}}},
"schemes":{"Dobby":{"build":{"targets":{"Dobby":"all"}}, "test":{"targets":["DobbyUITests"]}}}}
(output/'project.json').write_text(json.dumps(spec))
PY
xcodegen --spec "$test_dir/project.json" --project "$test_dir"
printf 'Test artifacts: %s\n' "$test_dir"
xcodebuild -project "$test_dir/DobbyValidation.xcodeproj" -scheme Dobby \
  -destination "$test_destination" -derivedDataPath "$test_dir/DerivedData" \
  -resultBundlePath "$test_dir/Results.xcresult" -parallel-testing-enabled NO test
