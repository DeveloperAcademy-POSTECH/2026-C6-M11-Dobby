#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/dobby-lidar-ui.XXXXXX)"
test_destination="${1:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4}"
if (( $# > 0 )); then shift; fi
# The opt-in photo test uses a disposable simulator, so fixtures cannot read,
# reorder, or remove a developer's existing photos. New imports precede stock
# sample photos in the fresh simulator's default Photos picker sort order.
photo_fixtures="${DOBBY_UI_PHOTO_FIXTURES:-0}"
photo_simulator=""
cleanup_photo_simulator() {
  if [[ -n "$photo_simulator" ]]; then
    xcrun simctl shutdown "$photo_simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$photo_simulator" >/dev/null 2>&1 || true
  fi
}
trap cleanup_photo_simulator EXIT
if [[ "$photo_fixtures" == "1" ]]; then
  photo_simulator="$(python3 - "$test_destination" <<'PYDEVICE'
import json, subprocess, sys
fields = dict(part.split('=', 1) for part in sys.argv[1].split(',') if '=' in part)
if fields.get('platform') != 'iOS Simulator':
    raise SystemExit('Photo fixtures require an iOS Simulator destination.')
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
matches = [(runtime, device) for runtime, values in devices.items() for device in values
           if (device['udid'] == fields['id'] if 'id' in fields else
               device['name'] == fields.get('name') and runtime.endswith('.iOS-' + fields.get('OS', '').replace('.', '-')))]
if len(matches) != 1:
    raise SystemExit('Photo fixtures require one explicit simulator name+OS or id.')
runtime, device = matches[0]
print(subprocess.check_output(['xcrun', 'simctl', 'create', 'Dobby photo UI fixtures', device['deviceTypeIdentifier'], runtime], text=True).strip())
PYDEVICE
)"
  test_destination="platform=iOS Simulator,id=$photo_simulator"
  xcrun simctl boot "$photo_simulator"
  xcrun simctl bootstatus "$photo_simulator" -b
fi
python3 - "$repo_dir" "$test_dir" "$photo_fixtures" <<'PY'
import json, pathlib, struct, sys, zlib
repo, output = map(pathlib.Path, sys.argv[1:3])
photo_fixtures = sys.argv[3] == '1'
if photo_fixtures:
    # Test-owned synthetic images, not training data or physical evidence.
    # The oversize PNG is valid media but exceeds the provider's 16,384 px
    # limit. Different terminal errors expose a stale result on replacement.
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    for name, width, height, color in [('oversize-white', 16385, 32, (255, 255, 255)), ('blank-blue', 192, 256, (32, 96, 160))]:
        rows = b''.join(b'\x00' + bytes(color) * width for _ in range(height))
        header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
        (output / (name + '.png')).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
settings = {"ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS":"YES", "SWIFT_VERSION":"5.0", "IPHONEOS_DEPLOYMENT_TARGET":"26.4", "CODE_SIGNING_ALLOWED":"NO", "SWIFT_DEFAULT_ACTOR_ISOLATION":"MainActor", "SWIFT_APPROACHABLE_CONCURRENCY":"YES", "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY":"YES"}
# Preserve the app URL registration without copying its Info.plist as a resource.
# The production widget target is validated by the native project build.
app_sources = [{"path":str(repo/'Dobby/Dobby'), "excludes":["QuickCopyInfo.plist"]},
               str(repo/'Dobby/ContentView.swift'), str(repo/'Dobby/DobbyApp.swift'),
               str(repo/'Dobby/Assets.xcassets')]
spec = {"name":"DobbyValidation", "options":{"deploymentTarget":{"iOS":"26.4"}}, "settings":{"base":settings}, "targets":{
"Dobby":{"type":"application", "platform":"iOS", "sources":app_sources, "settings":{"base":{"PRODUCT_BUNDLE_IDENTIFIER":"com.dobby.Dobby", "GENERATE_INFOPLIST_FILE":"YES", "INFOPLIST_FILE":str(repo/'Dobby/Dobby/QuickCopyInfo.plist'), "INFOPLIST_KEY_NSCameraUsageDescription":"옷 사진과 깊이로 길이를 측정합니다.", "INFOPLIST_KEY_UILaunchScreen_Generation":"YES", "INFOPLIST_KEY_UIApplicationSceneManifest_Generation":"YES", "INFOPLIST_KEY_UISupportedInterfaceOrientations":"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight", "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad":"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight", "TARGETED_DEVICE_FAMILY":"1,2"}}},
"DobbyUITests":{"type":"bundle.ui-testing", "platform":"iOS", "sources":[str(repo/'Tests/DobbyUITests')], "dependencies":[{"target":"Dobby"}], "settings":{"base":{"PRODUCT_BUNDLE_IDENTIFIER":"com.dobby.Dobby.UITests", "GENERATE_INFOPLIST_FILE":"YES", "TEST_TARGET_NAME":"Dobby"}}},
"DobbyPresentationTests":{"type":"bundle.unit-test", "platform":"iOS", "sources":[str(repo/'Tests/DobbyPresentationTests')], "dependencies":[{"target":"Dobby"}], "settings":{"base":{"PRODUCT_BUNDLE_IDENTIFIER":"com.dobby.Dobby.PresentationTests", "GENERATE_INFOPLIST_FILE":"YES"}}}},
"schemes":{"Dobby":{"build":{"targets":{"Dobby":"all"}}, "test":{"targets":["DobbyUITests", "DobbyPresentationTests"], "environmentVariables":{"DOBBY_UI_PHOTO_FIXTURES":"1" if photo_fixtures else "0"}}}}}
(output/'project.json').write_text(json.dumps(spec))
PY
if [[ -n "$photo_simulator" ]]; then
  xcrun simctl addmedia "$photo_simulator" "$test_dir/oversize-white.png" "$test_dir/blank-blue.png"
fi
xcodegen --spec "$test_dir/project.json" --project "$test_dir"
printf 'Test artifacts: %s\n' "$test_dir"
xcodebuild -project "$test_dir/DobbyValidation.xcodeproj" -scheme Dobby \
  -destination "$test_destination" -derivedDataPath "$test_dir/DerivedData" \
  -resultBundlePath "$test_dir/Results.xcresult" -parallel-testing-enabled NO "$@" test
