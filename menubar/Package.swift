// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ApproveGateBar",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "BarCore", path: "Sources/BarCore"),
        .executableTarget(name: "ApproveGateBar", dependencies: ["BarCore"], path: "Sources/ApproveGateBar"),
        .testTarget(name: "BarCoreTests", dependencies: ["BarCore"], path: "Tests/BarCoreTests"),
    ]
)
