// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SixtyFourVoice",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        .executableTarget(
            name: "SixtyFourVoice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/SixtyFourVoice",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
