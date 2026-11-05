// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveTranslateCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LiveTranslateCore", targets: ["LiveTranslateCore"]),
    ],
    targets: [
        .target(name: "LiveTranslateCore"),
        .testTarget(
            name: "LiveTranslateCoreTests",
            dependencies: ["LiveTranslateCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
