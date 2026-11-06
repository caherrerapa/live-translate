// swift-tools-version: 6.2
import PackageDescription

// Diarizer only. The default FluidAudio traits also pull a binary text-normalization
// engine that this app does not use.
let package = Package(
    name: "FluidAudioDiarizer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "FluidAudioDiarizer", targets: ["FluidAudioDiarizer"]),
    ],
    dependencies: [
        .package(path: "../FluidAudio"),
    ],
    targets: [
        .target(
            name: "FluidAudioDiarizer",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
