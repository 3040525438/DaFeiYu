import Foundation
import GRDB
import DFCore

/// 消息整理的唯一写入实现（D26：收藏 / 重要标记 / 分类标签）。
///
/// 事务边界：
/// - 每个方法都是**单一写事务**，批量操作不会出现"改了一半"；
/// - 标签写入先按归一化结果去重，同一消息同一标签只保留一行；
/// - 本仓储**不写 memories / persona_items**：收藏与标签不产生记忆，也不影响人格。
public struct GRDBMessageOrganizationRepository: MessageOrganizationRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 重要标记

    public func setImportant(id: String, isImportant: Bool, at millis: Int64) async throws {
        do {
            try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT deleted_at FROM messages WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MessageOrganizationError.notFound
                }
                guard Int64.fromDatabaseValue(row["deleted_at"]) == nil else {
                    throw MessageOrganizationError.deleted
                }
                let importantAt: Int64? = isImportant ? millis : nil
                try db.execute(
                    sql: "UPDATE messages SET is_important = ?, important_at = ? WHERE id = ?",
                    arguments: [isImportant, importantAt, id]
                )
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    // MARK: - 批量收藏

    @discardableResult
    public func setFavoriteBatch(ids: [String], isFavorite: Bool, at millis: Int64) async throws -> Int {
        let unique = Set(ids).sorted()
        guard !unique.isEmpty else { return 0 }
        do {
            return try await database.write { db in
                let favoritedAt: Int64? = isFavorite ? millis : nil
                var affected = 0
                for id in unique {
                    // 只统计状态真正变化的行：重复收藏不重复计数
                    try db.execute(
                        sql: """
                        UPDATE messages
                        SET is_favorite = ?, favorited_at = ?
                        WHERE id = ? AND deleted_at IS NULL AND is_favorite <> ?
                        """,
                        arguments: [isFavorite, favoritedAt, id, isFavorite]
                    )
                    affected += db.changesCount
                }
                return affected
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    // MARK: - 标签

    @discardableResult
    public func addTag(_ tag: String, to ids: [String], at millis: Int64) async throws -> Int {
        let normalized = Self.normalizeTag(tag)
        guard !normalized.isEmpty else { throw MessageOrganizationError.emptyTag }
        let unique = Set(ids).sorted()
        guard !unique.isEmpty else { return 0 }

        do {
            return try await database.write { db in
                var affected = 0
                for id in unique {
                    // 已删除或不存在的消息静默跳过：批量打标签不应因个别失效 id 整体失败
                    try db.execute(
                        sql: """
                        INSERT INTO message_tags (id, message_id, tag, created_at)
                        SELECT ?, ?, ?, ?
                        WHERE EXISTS (SELECT 1 FROM messages WHERE id = ? AND deleted_at IS NULL)
                          AND NOT EXISTS (SELECT 1 FROM message_tags WHERE message_id = ? AND tag = ?)
                        """,
                        arguments: [UUID().uuidString, id, normalized, millis, id, id, normalized]
                    )
                    affected += db.changesCount
                }
                return affected
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    @discardableResult
    public func removeTag(_ tag: String, from ids: [String]) async throws -> Int {
        let normalized = Self.normalizeTag(tag)
        guard !normalized.isEmpty else { return 0 }
        let unique = Set(ids).sorted()
        guard !unique.isEmpty else { return 0 }

        do {
            return try await database.write { db in
                var removed = 0
                for id in unique {
                    try db.execute(
                        sql: "DELETE FROM message_tags WHERE message_id = ? AND tag = ?",
                        arguments: [id, normalized]
                    )
                    removed += db.changesCount
                }
                return removed
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func tags(ofMessage id: String) async throws -> [String] {
        do {
            return try await database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT tag FROM message_tags WHERE message_id = ? ORDER BY tag ASC",
                    arguments: [id]
                )
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    public func tagSummary() async throws -> [MessageTagCount] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT tag, count(*) AS count
                    FROM message_tags
                    GROUP BY tag
                    ORDER BY count DESC, tag ASC
                    """
                ).map { row in
                    MessageTagCount(
                        tag: try row.decode(String.self, forColumn: "tag"),
                        count: try row.decode(Int.self, forColumn: "count")
                    )
                }
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    // MARK: - 列表

    public func messageIDs(filter: MessageFilter, limit: Int, offset: Int) async throws -> [String] {
        let clamped = min(max(limit, 1), 200)
        let skipped = max(offset, 0)

        var sql = "SELECT id FROM messages WHERE deleted_at IS NULL"
        var arguments: [any DatabaseValueConvertible] = []
        switch filter {
        case .all:
            break
        case .favorite:
            sql += " AND is_favorite = 1"
        case .important:
            sql += " AND is_important = 1"
        case let .tagged(rawTag):
            let normalized = Self.normalizeTag(rawTag)
            guard !normalized.isEmpty else { return [] }
            sql += " AND id IN (SELECT message_id FROM message_tags WHERE tag = ?)"
            arguments.append(normalized)
        }
        sql += " ORDER BY created_at DESC, id ASC LIMIT ? OFFSET ?"
        arguments.append(clamped)
        arguments.append(skipped)

        do {
            return try await database.dbQueue.read { db in
                try String.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            }
        } catch let error as DatabaseError {
            throw DFError.database(error.message ?? "数据库操作失败")
        }
    }

    // MARK: - 归一化

    /// 标签归一化：去首尾空白 → 去前导 `#` → 折叠连续空白。
    /// 空串或超长（> 24 字符）视为非法，避免把整段正文当标签写进库。
    static func normalizeTag(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var collapsed = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(character)
                lastWasSpace = false
            }
        }
        let normalized = collapsed.trimmingCharacters(in: .whitespaces)
        guard normalized.count <= GRDBMessageOrganizationRepository.maxTagLength else { return "" }
        return normalized
    }
}
