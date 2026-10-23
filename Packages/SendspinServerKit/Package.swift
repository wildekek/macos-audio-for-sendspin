// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SendspinServerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SendspinServerKit", targets: ["SendspinServerKit"]),
        .library(name: "SendspinAudio", targets: ["SendspinAudio"]),
        .library(name: "SendspinMenuUI", targets: ["SendspinMenuUI"]),
        .executable(name: "sendspin-bridge", targets: ["sendspin-bridge"]),
    ],
    targets: [
        .target(name: "SendspinServerKit"),
        // CoreAudio side: capture, device control, latency measurement.
        .target(name: "SendspinAudio", dependencies: ["SendspinServerKit"]),
        // The menu's rows in SwiftUI, drawn from `SpeakerMenu`: in the package so tests can render them.
        .target(name: "SendspinMenuUI", dependencies: ["SendspinServerKit"]),
        .executableTarget(name: "sendspin-bridge", dependencies: ["SendspinServerKit", "SendspinAudio"]),
        .testTarget(name: "SendspinServerKitTests", dependencies: ["SendspinServerKit"]),
        .testTarget(name: "SendspinAudioTests", dependencies: ["SendspinAudio"]),
        // Snapshots of the rows; their images live beside the tests (__Snapshots__).
        .testTarget(name: "SendspinMenuUITests", dependencies: ["SendspinMenuUI", "SendspinServerKit"],
                    exclude: ["__Snapshots__"]),
    ]
)
