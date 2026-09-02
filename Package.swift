// swift-tools-version:6.0
import PackageDescription

// One binary, two senses. `SenseVision` and `SenseAudio` are separate modules so
// their internal helpers (both define `fail`, both define an `Info` command) stay
// namespaced; only the root subcommand of each is public.
//
// The Info.plist is embedded into __TEXT,__info_plist of the *executable* — an
// unbundled CLI has nowhere else to put usage descriptions, and TCC kills the
// process without them. It therefore has to live on the SenseCLI target, which
// is the only one that produces a Mach-O with a __TEXT segment of its own.
let package = Package(
    name: "sense",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sense", targets: ["SenseCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SenseCore",
            path: "Sources/SenseCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SenseVision",
            dependencies: [
                "SenseCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SenseVision",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreML"),
            ]
        ),
        .target(
            name: "SenseAudio",
            dependencies: ["SenseCore"],
            path: "Sources/SenseAudio",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "SenseCLI",
            dependencies: [
                "SenseCore", "SenseVision", "SenseAudio",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SenseCLI",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
    ]
)
