import Foundation
import DFCore
import DFData

/// DFOrchestration 模块入口（B1-S2 仅建立包结构与依赖关系）。
///
/// 本模块是 `ChatOrchestrator` 的唯一生产实现落点：
/// - 依赖：`DFCore`（协议、纯逻辑）、`DFData`（GRDB 仓储）；
/// - 不依赖：`DFAI`（模型 Provider 由调用方以闭包注入）、任何新的外部依赖。
///
/// S3 才会加入 `ChatOrchestratorImpl`（事务 A/B/C、流式解析、状态机）；
/// 当前只保留一个编译期"依赖探针"，用于证明上述两条依赖真实成立。
public enum DFOrchestrationModule {
    /// 依赖探针：用 `DFData` 的真实仓储类型构造实例。
    ///
    /// 存在的唯一目的：让 `DFOrchestration → DFData` 的依赖在编译期被真正使用，
    /// 避免"声明了依赖但从未引用"而被误判为接线成功。
    public static func makeMessageGroupRepository(
        database: AppDatabase
    ) -> GRDBMessageGroupRepository {
        GRDBMessageGroupRepository(database: database)
    }

    /// 依赖探针：确认 `DFCore` 的编排协议对本模块可见。
    public static var orchestratorProtocolName: String {
        String(describing: ChatOrchestrator.self)
    }
}
