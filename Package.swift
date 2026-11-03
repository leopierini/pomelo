// swift-tools-version: 6.0
import PackageDescription

// Release builds optimize the shipped modules for size (the app's and the CLI's copies): about 10 % smaller with no
// measured cost in the wheel, editors, launch or any edge (Phase 6 Task 7). Debug and tests keep -Onone.
let sizeOptimized: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "Pomelo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PomeloCore", targets: ["PomeloCore"]),
        .library(name: "PomeloEngines", targets: ["PomeloEngines"]),
        .library(name: "PomeloUIModel", targets: ["PomeloUIModel"]),
        .executable(name: "pomelo", targets: ["pomelo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PomeloCore", swiftSettings: sizeOptimized),
        .target(
            name: "PomeloEngines",
            dependencies: ["PomeloCore"],
            resources: [.copy("Plugins")],
            swiftSettings: sizeOptimized
        ),
        .target(name: "PomeloUIModel", dependencies: ["PomeloCore"], swiftSettings: sizeOptimized),
        .target(name: "PomeloTestSupport", dependencies: ["PomeloCore", "PomeloEngines"]),
        .target(name: "PomeloCLIKit", dependencies: ["PomeloCore", "PomeloEngines"], swiftSettings: sizeOptimized),
        .target(name: "PomeloEvalsKit", dependencies: ["PomeloCore", "PomeloEngines", "PomeloTestSupport"]),
        .executableTarget(
            name: "pomelo-evals",
            dependencies: [
                "PomeloEvalsKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/PomeloEvals",
            linkerSettings: [
                // The edges ask `Installed.has("translation:en-it")` in this process, and Translation answers an app
                // linked against an older SDK as if no language were installed (see the pomelo target, P163).
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.4"]),
            ]
        ),
        .executableTarget(
            name: "pomelo",
            dependencies: [
                "PomeloCLIKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: sizeOptimized,
            linkerSettings: [
                // SwiftPM links the CLI claiming macOS 14 as its SDK, and Translation then answers as it does to an
                // old app: every installed language reads "supported" and sessions throw notInstalled (found below
                // SDK 26.4; 26.0 is not enough). Claiming 26.4 restores the real answers. The app, built by Xcode,
                // links with the real SDK, so building it needs Xcode 26.4 or later for the same reason.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.4"]),
                // Release only, so debug builds and tests keep their symbols: -S drops the debug map, which was most
                // of the binary, -x the local symbols. The release dSYM comes out empty as a result.
                .unsafeFlags(["-Xlinker", "-S", "-Xlinker", "-x"], .when(configuration: .release)),
            ]
        ),
        .testTarget(name: "PomeloCoreTests", dependencies: ["PomeloCore", "PomeloTestSupport"]),
        .testTarget(
            name: "PomeloEnginesTests", dependencies: ["PomeloEngines", "PomeloTestSupport"],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "PomeloUIModelTests", dependencies: ["PomeloUIModel", "PomeloTestSupport"]),
        .testTarget(name: "PomeloCLIKitTests", dependencies: ["PomeloCLIKit", "PomeloTestSupport"]),
        .testTarget(name: "PomeloEvalsKitTests", dependencies: ["PomeloEvalsKit", "PomeloTestSupport"]),
    ]
)
