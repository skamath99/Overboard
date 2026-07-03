// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PushFightCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PushFightCore", targets: ["PushFightCore"]),
    ],
    targets: [
        .target(name: "PushFightCore"),
        .testTarget(name: "PushFightCoreTests", dependencies: ["PushFightCore"]),
    ]
)
