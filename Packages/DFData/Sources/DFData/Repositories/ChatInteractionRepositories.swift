import Foundation
import GRDB
import DFCore

// MARK: - 编辑 / 撤回 / 收藏

/// 编辑、撤回、收藏的唯一写入实现。
///
/// 事务边界：每次操作都是**单一写事务**——留痕、正文、索引要么全成，要么全不成。
/// 撤回只写标记与状态，**绝不删除原文**。
public struct GRDBMessageEditingRepository: MessageEditingRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func editMessage(id: String, newText: String, editedAt: Int64) async throws -> MessageEditOutcome {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageInteractionError.emptyText }

        do {
            return try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT conversation_id, text, edited_at, edit_count, deleted_at, revoked_at
                    FROM messages WHERE id = ?
                    """,
                    arguments: [id]
                ) else {
                    throw MessageInteractionError.notFound
                }
                if Int64.fromDatabaseValue(row["deleted_at"]) != nil {
                    throw MessageInteractionError.deleted
                }
                if Int64.fromDatabaseValue(row["revoked_at"]) != nil {
                    throw MessageInteractionError.revoked
                }

                let conversationID = try row.decode(String.self, forColumn: "conversation_id")
                let before = try row.decode(String.self, forColumn: "text")
                let editCount = Int.fromDatabaseValue(row["edit_count"]) ?? 0

                // 内容没变化：不写留痕（避免编辑历史被空操作污染）
                guard before != trimmed else {
                    return MessageEditOutcome(
                        version: editCount,
                        editedAt: Int64.fromDatabaseValue(row["edited_at"]),
                        changed: false
                    )
                }

                let version = editCount + 1
                try db.execute(
                    sql: """
                    INSERT INTO message_edits
                        (id, message_id, version, before_text, after_text, edited_by, created_at)
                    VALUES (?, ?, ?, ?, ?, 'user', ?)
                    """,
                    arguments: [UUID().uuidString, id, version, before, trimmed, editedAt]
                )
                try db.execute(
                    sql: "UPDATE messages SET text = ?, edited_at = ?, edit_count = ? WHERE id = ?",
                    arguments: [trimmed, editedAt, version, id]
                )
                try MessageIndexer.index(
                    db: db,
                    messageID: id,
                    conversationID: conversationID,
                    text: trimmed
                )
                return MessageEditOutcome(version: version, editedAt: editedAt, changed: true)
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func revokeMessage(id: String, reason: String?, revokedAt: Int64) async throws {
        do {
            try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT deleted_at, revoked_at FROM messages WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MessageInteractionError.notFound
                }
                if Int64.fromDatabaseValue(row["deleted_at"]) != nil {
                    throw MessageInteractionError.deleted
                }
                if Int64.fromDatabaseValue(row["revoked_at"]) != nil {
                    throw MessageInteractionError.revoked
                }

                try db.execute(
                    sql: """
                    UPDATE messages
                    SET revoked_at = ?, revoke_reason = ?, status = 'recalled'
                    WHERE id = ? AND revoked_at IS NULL AND deleted_at IS NULL
                    """,
                    arguments: [revokedAt, reason, id]
                )
                guard db.changesCount == 1 else { throw MessageInteractionError.revoked }

                // 撤回后不再被搜索命中；正文仍完整保留在库里
                try MessageIndexer.remove(db: db, messageID: id)
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func setFavorite(id: String, isFavorite: Bool, at: Int64) async throws {
        do {
            try await database.write { db in
                guard try Bool.fetchOne(db, sql: "SELECT 1 FROM messages WHERE id = ?", arguments: [id]) != nil else {
                    throw MessageInteractionError.notFound
                }
                let favoritedAt: Int64? = isFavorite ? at : nil
                try db.execute(
                    sql: "UPDATE messages SET is_favorite = ?, favorited_at = ? WHERE id = ?",
                    arguments: [isFavorite, favoritedAt, id]
                )
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func editHistory(messageID: String) async throws -> [MessageEditRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT message_id, version, before_text, after_text, edited_by, created_at
                    FROM message_edits WHERE message_id = ? ORDER BY version ASC
                    """,
                    arguments: [messageID]
                ).map { row in
                    MessageEditRecord(
                        messageID: try row.decode(String.self, forColumn: "message_id"),
                        version: try row.decode(Int.self, forColumn: "version"),
                        beforeText: try row.decode(String.self, forColumn: "before_text"),
                        afterText: try row.decode(String.self, forColumn: "after_text"),
                        editedBy: try row.decode(String.self, forColumn: "edited_by"),
                        createdAt: try row.decode(Int64.self, forColumn: "created_at")
                    )
                }
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }
}

// MARK: - 删除体系

public struct GRDBMessageDeletionRepository: MessageDeletionRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func softDelete(
        _ scope: MessageDeleteScope,
        in conversationID: String?,
        at millis: Int64
    ) async throws -> Int {
        do {
            return try await database.write { db in
                let targets = try Self.targets(db, scope: scope, conversationID: conversationID)
                var affected = 0
                for id in targets {
                    // 会话约束在 UPDATE 里再校验一次：范围之外的消息一条都不动
                    try db.execute(
                        sql: """
                        UPDATE messages SET deleted_at = ?
                        WHERE id = ? AND deleted_at IS NULL
                          AND (? IS NULL OR conversation_id = ?)
                        """,
                        arguments: [millis, id, conversationID, conversationID]
                    )
                    guard db.changesCount == 1 else { continue }
                    affected += 1
                    try MessageIndexer.remove(db: db, messageID: id)
                }
                // 清空会话：用户删的是"会话里的消息"，不因 0 条命中就报错
                return affected
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    /// 计算候选 id（未软删）。真正的删除仍会在 UPDATE 里复核会话归属与软删状态。
    private static func targets(
        _ db: Database,
        scope: MessageDeleteScope,
        conversationID: String?
    ) throws -> [String] {
        switch scope {
        case let .ids(ids):
            return ids
        case let .dateRange(from, to):
            return try String.fetchAll(
                db,
                sql: """
                SELECT id FROM messages
                WHERE deleted_at IS NULL
                  AND (? IS NULL OR conversation_id = ?)
                  AND (? IS NULL OR created_at >= ?)
                  AND (? IS NULL OR created_at < ?)
                """,
                arguments: [conversationID, conversationID, from, from, to, to]
            )
        case let .keyword(keyword):
            let pattern = "%" + escapeLike(keyword) + "%"
            return try String.fetchAll(
                db,
                sql: """
                SELECT id FROM messages
                WHERE deleted_at IS NULL
                  AND (? IS NULL OR conversation_id = ?)
                  AND text LIKE ? ESCAPE '\\'
                """,
                arguments: [conversationID, conversationID, pattern]
            )
        case let .conversation(target):
            return try String.fetchAll(
                db,
                sql: "SELECT id FROM messages WHERE deleted_at IS NULL AND conversation_id = ?",
                arguments: [target]
            )
        }
    }

    /// LIKE 通配符转义：用户输入里的 `%` `_` `\` 一律按字面量匹配
    static func escapeLike(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}

// MARK: - 会话内搜索

public struct GRDBChatSearchRepository: ChatSearchRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func search(query: String, conversationID: String?, limit: Int) async throws -> [ChatSearchHit] {
        let tokens = V2Memory.bigram(query)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        // 每个 bigram 词加引号后 AND 组合，避免用户输入被当成 FTS 语法
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " AND ")
        let clamped = min(max(limit, 1), 100)

        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT message_id, conversation_id, bm25(message_fts) AS score
                    FROM message_fts
                    WHERE message_fts MATCH ?
                      AND (? IS NULL OR conversation_id = ?)
                      AND message_id IN (
                          SELECT id FROM messages WHERE deleted_at IS NULL AND revoked_at IS NULL
                      )
                    ORDER BY score ASC
                    LIMIT ?
                    """,
                    arguments: [match, conversationID, conversationID, clamped]
                ).map { row in
                    ChatSearchHit(
                        messageID: try row.decode(String.self, forColumn: "message_id"),
                        conversationID: try row.decode(String.self, forColumn: "conversation_id"),
                        score: try row.decode(Double.self, forColumn: "score")
                    )
                }
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func rebuildIndex(conversationID: String?) async throws -> Int {
        do {
            return try await database.write { db in
                if let conversationID {
                    try db.execute(
                        sql: "DELETE FROM message_fts WHERE conversation_id = ?",
                        arguments: [conversationID]
                    )
                } else {
                    try db.execute(sql: "DELETE FROM message_fts")
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, conversation_id, text FROM messages
                    WHERE deleted_at IS NULL AND revoked_at IS NULL
                      AND (? IS NULL OR conversation_id = ?)
                    """,
                    arguments: [conversationID, conversationID]
                )
                var indexed = 0
                for row in rows {
                    try MessageIndexer.index(
                        db: db,
                        messageID: try row.decode(String.self, forColumn: "id"),
                        conversationID: try row.decode(String.self, forColumn: "conversation_id"),
                        text: try row.decode(String.self, forColumn: "text")
                    )
                    indexed += 1
                }
                return indexed
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }
}

// MARK: - 主题存储

public struct GRDBChatThemeStore: ChatThemeStoring, Sendable {
    private let settings: any SettingsRepository

    public init(settings: any SettingsRepository) {
        self.settings = settings
    }

    public func load() async throws -> ChatTheme {
        guard let raw = try await settings.string(for: ChatTheme.storageKey),
              let data = raw.data(using: .utf8) else {
            return .default
        }
        // 坏数据不阻断聊天页：解析失败一律回落默认
        guard let decoded = try? JSONDecoder().decode(ChatTheme.self, from: data) else {
            return .default
        }
        return decoded.normalized()
    }

    public func save(_ theme: ChatTheme) async throws {
        let normalized = theme.normalized()
        let data = try JSONEncoder().encode(normalized)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw DFError.database("主题序列化失败")
        }
        try await settings.set(raw, for: ChatTheme.storageKey)
    }

    @discardableResult
    public func reset() async throws -> ChatTheme {
        try await save(.default)
        return .default
    }
}
