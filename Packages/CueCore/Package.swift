// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CueCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "CueCore", targets: ["Geometry", "Physics", "Rules", "Engine", "Stats", "Training"]),
    ],
    targets: [
        .target(name: "Geometry"),
        .target(name: "Physics", dependencies: ["Geometry"]),
        .target(name: "Rules", dependencies: ["Geometry"]),
        .target(name: "Engine", dependencies: ["Geometry", "Physics", "Rules"]),
        .target(name: "Stats", dependencies: ["Geometry", "Rules"]),
        .target(name: "Training", dependencies: ["Geometry"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry"]),
        .testTarget(name: "PhysicsTests", dependencies: ["Physics"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RulesTests", dependencies: ["Rules"]),
        .testTarget(name: "EngineTests", dependencies: ["Engine"]),
        .testTarget(name: "StatsTests", dependencies: ["Stats"]),
        .testTarget(name: "TrainingTests", dependencies: ["Training"]),
    ],
    swiftLanguageModes: [.v6]
)
