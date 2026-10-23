// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SendspinServerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SendspinServerKit", targets: ["SendspinServerKit"]),
        .library(name: "SendspinAudio", targets: ["SendspinAudio"]),
        .executable(name: "sendspin-bridge", targets: ["sendspin-bridge"]),
    ],
    targets: [
        .target(name: "SendspinServerKit"),
        // CoreAudio side: capture, device control, latency measurement.
        .target(name: "SendspinAudio", dependencies: ["SendspinServerKit"]),
        .executableTarget(name: "sendspin-bridge", dependencies: ["SendspinServerKit", "SendspinAudio"]),
        .testTarget(name: "SendspinServerKitTests", dependencies: ["SendspinServerKit"]),
        .testTarget(name: "SendspinAudioTests", dependencies: ["SendspinAudio"]),
    ]
)
