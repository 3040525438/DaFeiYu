// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DFCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "DFCore", targets: ["DFCore"])
    ],
    targets: [
        .target(name: "DFCore"),
        .testTarget(name: "DFCoreTests", dependencies: ["DFCore"])
    ]
)
