// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightTable",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightTable", targets: ["LightTableApp"])],
    targets: [
        .target(name: "LightTableCore"),
        .executableTarget(name: "LightTableApp", dependencies: ["LightTableCore"]),
        .testTarget(name: "LightTableCoreTests", dependencies: ["LightTableCore"])
    ]
)
