import Foundation
import GRDB
import DFCore

/// 上下文单元提供者：把库中的"真实组"与"无组历史消息"统一成 A1 的 `ContextUnit` 序列。
///
/// 关键语义（A2 裁决）：
/// - `limitGroups` **只限制真实 `message_groups` 的个数**；
/// - v2 遗留的无组消息**不受** `limitGroups` 限制，每条自成虚拟组，绝不会因
///   `limitGroups = 20` 而被静默丢弃；
/// - 两类单元按 `(created_at, rowid)` 归并，保证时间顺序稳定；
/// - 软删 / 失败 / 撤回的过滤由 `ContextComposer` 负责，本层只负责取全。
public struct GRDBContextUnitProvider: ContextUnitProviding, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func recentUnits(conversationID: String, limitGroups: Int) async throws -> [ContextUnit] {
        do {
            return try await database.dbQueue.read { db in
                // (createdAt, rowid) 作为归并键
                var keyed: [(createdAt: Int64, rowid: Int64, unit: ContextUnit)] = []

                // 1. 无组历史消息：每条一个虚拟组，不设数量上限
                let legacy = try MessageRow.fetchAll(
                    db,
                    sql: """
                    SELECT messages.*, messages.rowid AS _rid
                    FROM messages
                    WHERE messages.conversation_id = ? AND messages.group_id IS NULL
                    ORDER BY messages.created_at ASC, messages.rowid ASC
                    """,
                    arguments: [conversationID]
                )
                for row in legacy {
                    keyed.append((
                        row.message.createdAt,
                        row.rowid,
                        ContextUnit.virtual(row.message)
                    ))
                }

                // 2. 最近 limitGroups 个真实组（turn_index 单调，倒序取再反转即时间升序）
                let limit = max(0, limitGroups)
                if limit > 0 {
                    let groups = try MessageGroup
                        .filter(Column("conversation_id") == conversationID)
                        .order(Column("turn_index").desc)
                        .limit(limit)
                        .fetchAll(db)
                        .reversed()

                    for group in groups {
                        let rows = try MessageRow.fetchAll(
                            db,
                            sql: """
                            SELECT messages.*, messages.rowid AS _rid
                            FROM messages
                            WHERE messages.group_id = ?
                            ORDER BY messages.created_at ASC, messages.rowid ASC
                            """,
                            arguments: [group.id]
                        )
                        guard let first = rows.first else { continue }
                        keyed.append((
                            first.message.createdAt,
                            first.rowid,
                            ContextUnit(group: group, messages: rows.map(\.message))
                        ))
                    }
                }

                keyed.sort { ($0.createdAt, $0.rowid) < ($1.createdAt, $1.rowid) }
                return keyed.map(\.unit)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}
