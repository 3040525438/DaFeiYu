import Foundation
import GRDB
import DFCore

/// 多会话管理的唯一写入实现（W3）。
///
/// 约束：
/// - 所有写操作单事务完成；
/// - 列表排序口径唯一，避免 UI 与测试各写一套；
/// - 删除会话只删消息与索引，**不碰 memories**（D11 / D51）。
public struct GRDBConversationAdminRepository: ConversationAdminRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 列表查询的统一投影：消息计数与最近消息时间都是实时子查询，
    /// 不额外维护冗余列，避免出现"会话列表说有 10 条、实际 9 条"。
    private static let summarySelect = """
    SELECT c.id, c.title, c.kind, c.created_at, c.updated_at, c.archived_at,
           c.pinned_at, c.sort_index, c.unread_count, c.last_read_at,
           (SELECT count(*) FROM messages m
             WHERE m.conversation_id = c.id AND m.deleted_at IS NULL) AS message_count,
           (SELECT max(m.created_at) FROM messages m
             WHERE m.conversation_id = c.id AND m.deleted_at IS NULL) AS last_message_at
    FROM conversations c
    """

    /// 置顶优先 → 排序号升序 → 最近活动倒序 → id 升序（稳定）
    private static let summaryOrder = """
    ORDER BY (c.pinned_at IS NULL) ASC, c.pinned_at DESC, c.sort_index ASC,
             c.updated_at DESC, c.id ASC
    """

    // MARK: - 建 / 改名

    public func create(title: String, kind: String, at millis: Int64) async throws -> ConversationSummary {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversationAdminError.emptyTitle }
        let safeKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "chat" : kind
        let id = UUID().uuidString

        do {
            return try await database.write { db in
                // 新会话排在未置顶会话的最前：sort_index 取当前最小值 - 1
                let minIndex = try Int.fetchOne(
                    db,
                    sql: "SELECT min(sort_index) FROM conversations WHERE pinned_at IS NULL"
                ) ?? 0
                try db.execute(
                    sql: """
                    INSERT INTO conversations
                        (id, title, kind, created_at, updated_at, sort_index, unread_count)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    """,
                    arguments: [id, trimmed, safeKind, millis, millis, minIndex - 1]
                )
                return try Self.fetchSummary(db, id: id)
                    ?? ConversationSummary(
                        id: id, title: trimmed, kind: safeKind,
                        createdAt: millis, updatedAt: millis, sortIndex: minIndex - 1
                    )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func rename(id: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversationAdminError.emptyTitle }
        do {
            try await database.write { db in
                try Self.requireExisting(db, id: id)
                // 只改标题：改名不算"最近活动"，不能把会话顶到列表最前
                try db.execute(
                    sql: "UPDATE conversations SET title = ? WHERE id = ?",
                    arguments: [trimmed, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 置顶 / 归档

    public func setPinned(id: String, pinned: Bool, at millis: Int64) async throws {
        do {
            try await database.write { db in
                try Self.requireExisting(db, id: id)
                try db.execute(
                    sql: "UPDATE conversations SET pinned_at = ? WHERE id = ?",
                    arguments: [pinned ? millis : nil, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func setArchived(id: String, archived: Bool, at millis: Int64) async throws {
        do {
            try await database.write { db in
                let kind = try Self.requireExisting(db, id: id)
                if kind == "main" {
                    throw ConversationAdminError.mainConversationProtected
                }
                try db.execute(
                    sql: "UPDATE conversations SET archived_at = ? WHERE id = ?",
                    arguments: [archived ? millis : nil, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 排序

    public func reorder(ids: [String]) async throws {
        do {
            try await database.write { db in
                let current = try String.fetchAll(
                    db,
                    sql: "SELECT c.id FROM conversations c \(Self.summaryOrder)"
                )
                let known = Set(current)
                var ordered: [String] = []
                var seen = Set<String>()
                for id in ids where known.contains(id) && !seen.contains(id) {
                    ordered.append(id)
                    seen.insert(id)
                }
                ordered.append(contentsOf: current.filter { !seen.contains($0) })

                for (index, id) in ordered.enumerated() {
                    try db.execute(
                        sql: "UPDATE conversations SET sort_index = ? WHERE id = ?",
                        arguments: [index, id]
                    )
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 查询

    public func list(_ filter: ConversationListFilter) async throws -> [ConversationSummary] {
        do {
            return try await database.dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    \(Self.summarySelect)
                    WHERE (? = 'all'
                           OR (? = 'active' AND c.archived_at IS NULL)
                           OR (? = 'archived' AND c.archived_at IS NOT NULL))
                    \(Self.summaryOrder)
                    """,
                    arguments: [filter.rawValue, filter.rawValue, filter.rawValue]
                )
                return try rows.map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func summary(id: String) async throws -> ConversationSummary? {
        do {
            return try await database.dbQueue.read { db in
                try Self.fetchSummary(db, id: id)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 未读

    public func incrementUnread(id: String, by delta: Int, at millis: Int64) async throws {
        do {
            try await database.write { db in
                try Self.requireExisting(db, id: id)
                try db.execute(
                    sql: """
                    UPDATE conversations
                    SET unread_count = max(0, unread_count + ?), updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [delta, millis, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func markRead(id: String, at millis: Int64) async throws {
        do {
            try await database.write { db in
                try Self.requireExisting(db, id: id)
                try db.execute(
                    sql: """
                    UPDATE conversations
                    SET unread_count = 0, last_read_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [millis, millis, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    @discardableResult
    public func markAllRead(at millis: Int64) async throws -> Int {
        do {
            return try await database.write { db in
                // 返回值只统计"原本有未读"的会话数；last_read_at 对所有会话都落一次，
                // 保证列表里每条会话都有明确的已读时间（没有未读的会话也刷新为本次阅读时间）
                let affected = try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM conversations WHERE unread_count > 0"
                ) ?? 0
                try db.execute(
                    sql: """
                    UPDATE conversations
                    SET unread_count = 0,
                        last_read_at = ?,
                        updated_at = CASE WHEN unread_count > 0 THEN ? ELSE updated_at END
                    """,
                    arguments: [millis, millis]
                )
                return affected
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func unreadTotal() async throws -> Int {
        do {
            return try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(unread_count), 0) FROM conversations"
                ) ?? 0
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 删除

    @discardableResult
    public func delete(id: String) async throws -> ConversationDeletionResult {
        try await deleteBatch(ids: [id])
    }

    @discardableResult
    public func deleteBatch(ids: [String]) async throws -> ConversationDeletionResult {
        do {
            return try await database.write { db in
                var result = ConversationDeletionResult()
                for id in Set(ids) {
                    guard let kind = try String.fetchOne(
                        db,
                        sql: "SELECT kind FROM conversations WHERE id = ?",
                        arguments: [id]
                    ) else {
                        continue // 不存在即无需删除，保持幂等
                    }
                    if kind == "main" {
                        result.skippedProtected += 1
                        continue
                    }

                    let messageCount = try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM messages WHERE conversation_id = ?",
                        arguments: [id]
                    ) ?? 0

                    // 消息的 FTS 行不随 messages 级联，必须显式清理，否则会留下"幽灵命中"
                    if try db.tableExists("message_fts") {
                        try db.execute(
                            sql: "DELETE FROM message_fts WHERE conversation_id = ?",
                            arguments: [id]
                        )
                    }
                    try db.execute(
                        sql: "DELETE FROM messages WHERE conversation_id = ?",
                        arguments: [id]
                    )
                    // 记忆不在级联链上：memory_sources 只记录 source_id 文本，
                    // 因此删除会话后记忆仍完整保留（D11）。
                    try db.execute(
                        sql: "DELETE FROM conversations WHERE id = ?",
                        arguments: [id]
                    )

                    result.deletedConversations += 1
                    result.deletedMessages += messageCount
                }
                return result
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 内部

    /// 校验存在性并返回 kind；不存在抛 `notFound`。
    @discardableResult
    private static func requireExisting(_ db: Database, id: String) throws -> String {
        guard let kind = try String.fetchOne(
            db,
            sql: "SELECT kind FROM conversations WHERE id = ?",
            arguments: [id]
        ) else {
            throw ConversationAdminError.notFound
        }
        return kind
    }

    private static func fetchSummary(_ db: Database, id: String) throws -> ConversationSummary? {
        guard let row = try Row.fetchOne(
            db,
            sql: "\(summarySelect) WHERE c.id = ?",
            arguments: [id]
        ) else {
            return nil
        }
        return try decode(row)
    }

    private static func decode(_ row: Row) throws -> ConversationSummary {
        ConversationSummary(
            id: try row.decode(String.self, forColumn: "id"),
            title: try row.decode(String.self, forColumn: "title"),
            kind: try row.decode(String.self, forColumn: "kind"),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            updatedAt: try row.decode(Int64.self, forColumn: "updated_at"),
            archivedAt: Int64.fromDatabaseValue(row["archived_at"]),
            pinnedAt: Int64.fromDatabaseValue(row["pinned_at"]),
            sortIndex: Int.fromDatabaseValue(row["sort_index"]) ?? 0,
            unreadCount: Int.fromDatabaseValue(row["unread_count"]) ?? 0,
            lastReadAt: Int64.fromDatabaseValue(row["last_read_at"]),
            messageCount: Int.fromDatabaseValue(row["message_count"]) ?? 0,
            lastMessageAt: Int64.fromDatabaseValue(row["last_message_at"])
        )
    }
}
