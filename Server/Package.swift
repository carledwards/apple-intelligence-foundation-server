// swift-tools-version: 5.9
import PackageDescription

// The HTTP interface. Everything that knows about the model lives in Core; this
// target only maps JSON onto it. Vapor is declared here and nowhere else, so an
// app linking Core never resolves it.
let package = Package(
    name: "FoundationServer",
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0")
    ],
    targets: [
        .executableTarget(
            name: "FoundationServer",
            dependencies: [
                .product(name: "FoundationCore", package: "Core"),
                .product(name: "Vapor", package: "vapor")
            ]
        )
    ]
)
