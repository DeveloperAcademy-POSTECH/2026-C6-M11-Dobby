// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DobbyLiDARCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "DobbyLiDARCore", targets: ["DobbyLiDARCore"])],
    targets: [
        .target(name: "DobbyLiDARCore", path: "Dobby/Dobby/LiDAR/Core"),
        .testTarget(name: "DobbyLiDARCoreTests", dependencies: ["DobbyLiDARCore"], path: "Tests/DobbyLiDARCoreTests")
    ]
)
