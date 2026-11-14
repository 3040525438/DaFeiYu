// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DFData",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "DFData", targets: ["DFData"]),
        // B1-S2：编排层以"同包独立 target"形式提供（方案 B），
        // 好处是现有 CI 的 `swift test --package-path Packages/DFData` 会自动执行其测试 target。
        .library(name: "DFOrchestration", targets: ["DFOrchestration"])
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
        // 只依赖 DFCore（协议/纯逻辑）与 DFData（仓储），不依赖 DFAI、不引入新外部依赖。
        .target(
            name: "DFOrchestration",
            dependencies: [
                "DFCore",
                "DFData"
            ]
        ),
        .testTarget(name: "DFDataTests", dependencies: ["DFData"]),
        .testTarget(
            name: "DFOrchestrationTests",
            dependencies: ["DFOrchestration", "DFData"]
        )
    ]
)
