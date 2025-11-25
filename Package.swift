// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FoundataionsServer",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0")
    ],
    targets: [
        .executableTarget(
            name: "FoundationsServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ]
        )
    ]
)
