// swift-tools-version: 6.2
// Created by mason on 10/21/26.
import PackageDescription

// run-camera-backend-tests.sh가 실제 소스를 연결한 임시 폴더에서 사용한다.
let package = Package(name: "DetailCameraBackendVerification", platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Dobby", path: "Sources", swiftSettings: [.unsafeFlags([
            "-default-isolation", "MainActor", "-enable-upcoming-feature", "MemberImportVisibility"
        ])]),
        .testTarget(name: "BoundaryTests", dependencies: ["Dobby"], path: "Tests")
    ], swiftLanguageModes: [.v5])
