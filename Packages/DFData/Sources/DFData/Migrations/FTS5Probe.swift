import Foundation
import GRDB
import DFCore

/// FTS5 能力探测协议。
///
/// 单独抽出协议，是为了让"不可用"这条分支能被真实测试注入，
/// 而不是靠伪造编译选项或 SQL 演练。
protocol FTS5Probing: Sendable {
    /// 真实探测当前运行环境是否具备可用（可建表、可检索、可清理）的 FTS5。
    /// - Throws: 探测失败时抛出带具体原因的 `DFError.unsupported`
    func verify() throws
}

/// 默认实现：在一个**独立的内存库**里完整走一遍 FTS5 生命周期。
///
/// 为什么不查 `sqlite_compileoption_used('ENABLE_FTS5')`：
/// Apple 平台的系统 SQLite 可能没有把该编译选项登记进选项表，
/// 会出现"能力其实有、探测却说没有"的误判，从而误阻断迁移。
///
/// 隔离性：
/// - 使用 `:memory:` 独立连接，不打开、不写入业务数据库；
/// - 只建 `fts5_probe` 临时业务表并显式 `DROP`，库随连接释放一起销毁；
/// - 因此不会在业务库里留下任何表、记录或迁移台账变化。
struct MemoryFTS5Probe: FTS5Probing {
    func verify() throws {
        do {
            let queue = try DatabaseQueue(path: ":memory:")
            try queue.write { db in
                try db.execute(sql: "CREATE VIRTUAL TABLE fts5_probe USING fts5(body)")

                try db.execute(
                    sql: "INSERT INTO fts5_probe(body) VALUES(?)",
                    arguments: ["摄影 记忆 能力探测"]
                )

                let hits = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM fts5_probe WHERE fts5_probe MATCH '摄影'"
                ) ?? 0
                guard hits == 1 else {
                    throw DFError.unsupported("FTS5 探测未命中预期记录（命中 \(hits) 条）")
                }

                let missHits = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM fts5_probe WHERE fts5_probe MATCH '不存在的词'"
                ) ?? 0
                guard missHits == 0 else {
                    throw DFError.unsupported("FTS5 探测出现误命中（命中 \(missHits) 条）")
                }

                // 清理：显式删除并确认没有残留对象
                try db.execute(sql: "DROP TABLE fts5_probe")
                let left = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM sqlite_master WHERE name = 'fts5_probe'"
                ) ?? 0
                guard left == 0 else {
                    throw DFError.unsupported("FTS5 探测清理失败（残留 \(left) 个对象）")
                }
            }
            // queue 离开作用域即关闭，内存库随之销毁
        } catch let error as DFError {
            throw error
        } catch {
            throw DFError.unsupported("FTS5 探测失败：\(error.localizedDescription)")
        }
    }
}
