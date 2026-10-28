// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightTable",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightTable", targets: ["LightTableApp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .binaryTarget(name: "LightTableEDR", path: "Binaries/LightTableEDR.xcframework"),
        .target(name: "LightTableCore", dependencies: ["LightTableEDR"]),
        .executableTarget(name: "LightTableApp", dependencies: ["LightTableCore", "LightTableEDR", .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.process("Resources/ShutterClick.wav"),
                                      .process("Resources/SlideChange.wav"),
                                      .process("Resources/ProjectorStart.wav"),
                                      .process("Resources/ShutterClickRoom.wav"),
                                      .process("Resources/ShutterArrivalRoom.wav"),
                                      .copy("Resources/FilmTransmission.cube"),
                                      .copy("Resources/FilmTransmission.json"),
                                      .copy("Resources/ReturnToPast")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LightTableCoreTests", dependencies: ["LightTableCore"])
    ]
)
