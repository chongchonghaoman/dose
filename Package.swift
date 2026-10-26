// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightTable",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightTable", targets: ["LightTableApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "LightTableCore"),
        .executableTarget(name: "LightTableApp", dependencies: ["LightTableCore", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.process("Resources/ShutterClick.wav"),
                                      .process("Resources/ShutterClickRoom.wav"),
                                      .process("Resources/ShutterArrivalRoom.wav"),
                                      .copy("Resources/ReturnToPast")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LightTableCoreTests", dependencies: ["LightTableCore"])
    ]
)
