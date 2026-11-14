import XCTest
import Foundation
import DFCore
import DFData
import DFOrchestration

/// B1-S2 骨架测试：只验证"包结构 + 依赖关系"成立，不含任何编排逻辑。
///
/// 这两个用例同时是 C2 的计数器：CI 中 DFData 包的总测试数应从 94 变为 96。
final class DFOrchestrationSkeletonTests: XCTestCase {

    // MARK: - S2-01 依赖 DFData 真实成立（编译期 + 运行期）

    func testS2_01_ModuleCanConstructRealRepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFS2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 真实建库 + 真实迁移（不 mock）
        let database = try AppDatabase(paths: DatabasePaths(root: root))
        XCTAssertFalse(database.isReadOnly, "临时库迁移后应处于可写状态")

        let repository = DFOrchestrationModule.makeMessageGroupRepository(database: database)
        XCTAssertEqual(
            String(describing: type(of: repository)),
            "GRDBMessageGroupRepository"
        )
    }

    // MARK: - S2-02 依赖 DFCore 真实成立（协议可见）

    func testS2_02_ModuleSeesDFCoreOrchestratorProtocol() {
        let name = DFOrchestrationModule.orchestratorProtocolName
        XCTAssertTrue(
            name.hasSuffix("ChatOrchestrator"),
            "DFOrchestration 必须能看到 DFCore 的编排协议，实际：\(name)"
        )
    }
}
