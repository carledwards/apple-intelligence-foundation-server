// swift-tools-version: 5.9
import PackageDescription

// The model layer, with no server in it. Deliberately dependency-free so an app
// target linking this does not resolve Vapor and its ~28 transitive packages —
// SwiftPM resolves a dependency's entire manifest graph, not just the products
// you consume.
let package = Package(
    name: "FoundationCore",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0")
    ],
    products: [
        .library(name: "FoundationCore", targets: ["FoundationCore"])
    ],
    targets: [
        .target(name: "FoundationCore")
    ]
)
