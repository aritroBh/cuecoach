// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BenchCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "BenchCore", targets: ["BenchCore"])],
    targets: [
        .target(name: "BenchCore"),
        .testTarget(name: "BenchCoreTests", dependencies: ["BenchCore"]),
    ]
)
