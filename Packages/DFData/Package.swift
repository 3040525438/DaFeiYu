// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DFData",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "DFData", targets: ["DFData"])
    ],
    dependencies: [
        .package(path: "../DFCore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "DFData",
            dependencies: [
                "DFCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(name: "DFDataTests", dependencies: ["DFData"])
    ]
)
