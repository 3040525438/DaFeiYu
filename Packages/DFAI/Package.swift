// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DFAI",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "DFAI", targets: ["DFAI"])
    ],
    dependencies: [
        .package(path: "../DFCore")
    ],
    targets: [
        .target(name: "DFAI", dependencies: ["DFCore"]),
        .testTarget(name: "DFAITests", dependencies: ["DFAI"])
    ]
)
