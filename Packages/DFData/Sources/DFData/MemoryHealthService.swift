import Foundation
import GRDB
import DFCore

/// 记忆链路自检（第九/十/十八条）。
///
/// 只读：**不删除、不改写任何原始数据**，只把"数据库里真实存在的不一致"报出来，
/// 让用户能在诊断页看到：
/// - 有多少条记忆、多少已归档/已删除；
/// - 检索索引与记忆正文是否对得上（缺失或多余）；
/// - 有多少条记忆没有来源（无法追溯）；
/// - 有多少条处于推断/待确认状态；
/// - 有多少组疑似重复。
///
/// 明确边界：以下环节**只能运行时观测**，这里不伪造计数——
/// 「检索是否执行」「结果是否进入模型上下文」「模型是否真的用了记忆」。
public struct MemoryHealthReport: Sendable, Equatable {
    public var active: Int
    public var archived: Int
    public var deleted: Int
    /// 检索索引中的行数
    public var indexed: Int
    /// 有效记忆但索引缺失（检索永远搜不到）
    public var missingIndex: Int
    /// 索引存在但记忆已删/不存在（可能被重新召回）
    public var orphanIndex: Int
    /// 有效记忆但没有任何来源
    public var withoutSource: Int
    /// 推断 / 待确认状态条数
    public var unconfirmed: Int
    /// 疑似重复组数（同 dedupe_key 多于一条）
    public var duplicateGroups: Int
    public var checkedAt: Int64

    /// 整体是否健康
    public var isHealthy: Bool {
        missingIndex == 0 && orphanIndex == 0 && duplicateGroups == 0
    }
}

public struct MemoryHealthService: Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    public func check() async throws -> MemoryHealthReport {
        let stamp = now()
        return try await database.dbQueue.read { db in
            func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
                try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
            }

            let active = try count("SELECT count(*) FROM memories WHERE deleted_at IS NULL AND archived_at IS NULL")
            let archived = try count("SELECT count(*) FROM memories WHERE deleted_at IS NULL AND archived_at IS NOT NULL")
            let deleted = try count("SELECT count(*) FROM memories WHERE deleted_at IS NOT NULL")

            let hasFTS = try db.tableExists("memory_fts")
            let indexed = hasFTS ? try count("SELECT count(*) FROM memory_fts") : 0

            let missingIndex: Int
            let orphanIndex: Int
            if hasFTS {
                missingIndex = try count(
                    """
                    SELECT count(*) FROM memories m
                    WHERE m.deleted_at IS NULL AND m.archived_at IS NULL
                      AND NOT EXISTS (SELECT 1 FROM memory_fts f WHERE f.memory_id = m.id)
                    """
                )
                orphanIndex = try count(
                    """
                    SELECT count(*) FROM memory_fts f
                    WHERE NOT EXISTS (
                        SELECT 1 FROM memories m
                        WHERE m.id = f.memory_id AND m.deleted_at IS NULL
                    )
                    """
                )
            } else {
                missingIndex = active
                orphanIndex = 0
            }

            let withoutSource = try count(
                """
                SELECT count(*) FROM memories m
                WHERE m.deleted_at IS NULL AND m.archived_at IS NULL
                  AND NOT EXISTS (SELECT 1 FROM memory_sources s WHERE s.memory_id = m.id)
                """
            )

            let unconfirmed = try count(
                """
                SELECT count(*) FROM memories
                WHERE deleted_at IS NULL
                  AND epistemic_status IN ('inferred', 'unconfirmed', 'pending')
                """
            )

            let duplicateGroups = try count(
                """
                SELECT count(*) FROM (
                    SELECT dedupe_key FROM memories
                    WHERE deleted_at IS NULL AND dedupe_key IS NOT NULL AND dedupe_key <> ''
                    GROUP BY dedupe_key HAVING count(*) > 1
                )
                """
            )

            return MemoryHealthReport(
                active: active,
                archived: archived,
                deleted: deleted,
                indexed: indexed,
                missingIndex: missingIndex,
                orphanIndex: orphanIndex,
                withoutSource: withoutSource,
                unconfirmed: unconfirmed,
                duplicateGroups: duplicateGroups,
                checkedAt: stamp
            )
        }
    }

    /// 重建索引：只补缺失项、清理多余项，不动记忆正文。
    @discardableResult
    public func repairIndex() async throws -> Int {
        try await database.write { db in
            guard try db.tableExists("memory_fts") else { return 0 }
            try db.execute(
                sql: """
                DELETE FROM memory_fts
                WHERE memory_id NOT IN (SELECT id FROM memories WHERE deleted_at IS NULL)
                """
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, scope, title, content FROM memories
                WHERE deleted_at IS NULL
                  AND id NOT IN (SELECT memory_id FROM memory_fts)
                """
            )
            var repaired = 0
            for row in rows {
                let id = String.fromDatabaseValue(row["id"]) ?? ""
                let scope = String.fromDatabaseValue(row["scope"]) ?? "shared"
                let title = String.fromDatabaseValue(row["title"]) ?? ""
                let content = String.fromDatabaseValue(row["content"]) ?? ""
                guard !id.isEmpty else { continue }
                let bigram = V2Memory.bigram(title + " " + content)
                guard !bigram.isEmpty else { continue }
                try db.execute(
                    sql: "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, ?, ?)",
                    arguments: [id, scope, bigram]
                )
                repaired += 1
            }
            return repaired
        }
    }
}
