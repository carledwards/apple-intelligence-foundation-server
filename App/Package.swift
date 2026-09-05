// swift-tools-version: 5.9
import PackageDescription

// The app.
//
// `FoundationAppKit` holds every view and model and builds for macOS *and* iOS.
// `FoundationAppMac` is a thin runnable shell for the Mac with no Xcode project
// involved. The bundled app targets — `../iOS` and `../macOS` — link
// FoundationAppKit and supply only an entry point.
let package = Package(
    name: "FoundationApp",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0")
    ],
    products: [
        .library(name: "FoundationAppKit", targets: ["FoundationAppKit"]),
        .executable(name: "FoundationAppMac", targets: ["FoundationAppMac"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "FoundationAppKit",
            dependencies: [.product(name: "FoundationCore", package: "Core")]
        ),
        .executableTarget(
            name: "FoundationAppMac",
            dependencies: ["FoundationAppKit"],
            // Consumed by the linker below, not compiled as a source.
            exclude: ["Info.plist"],
            // A SwiftPM executable is a bare binary with no Info.plist, so it has
            // no bundle identifier and macOS refuses it the services that key off
            // one (App Intents registration, the process registry, window tab
            // indexing) — a wall of 4097 errors at every launch. Embedding a
            // plist in a __TEXT,__info_plist section gives the binary an identity
            // without making it a bundle.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/FoundationAppMac/Info.plist"
                ])
            ]
        )
    ]
)
