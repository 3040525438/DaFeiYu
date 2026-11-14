import Foundation
import GRDB
import DFCore

/// 记忆仓储（W8）。
///
/// 规则：
/// - 正文变更一律"版本 +1 + 全量快照"，不覆盖历史；
/// - 三套归属（user / shared / self）只通过 `scope` 区分，不拆表；
/// - 删除是软删，且可按来源批量清理（D19）；
/// - 全文索引由应用层 bigram 生成，与 v2 口径一致。
public struct GRDBMemoryRepository: MemoryRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let columns = """
    id, type, title, content, importance, importance_score, importance_source,
    salience, confidence, status, scope, layer, category, source_kind, epistemic_status,
    version, dedupe_key, heat, classification_status, created_at, updated_at,
    first_seen_at, last_recalled_at, recall_count, archived_at, deleted_at
    """

    private static let validScopes = Set(MemoryScope.allCases.map(\.rawValue))
    private static let validEditors = ["user", "ai", "migration", "system"]

    // MARK: - 写入

    @discardableResult
    public func insert(_ draft: MemoryDraft, at millis: Int64) async throws -> MemoryRecord {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw MemoryError.emptyContent }
        guard Self.validScopes.contains(draft.scope.rawValue) else {
            throw MemoryError.invalidScope(draft.scope.rawValue)
        }
        guard !draft.layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryError.invalidLayer(draft.layer)
        }

        do {
            return try await database.write { db in
                // 去重优先：同一事实重复出现只补来源，不新增行
                if let key = draft.dedupeKey, !key.isEmpty,
                   let existingRow = try Row.fetchOne(
                       db,
                       sql: """
                       SELECT \(Self.columns) FROM memories
                       WHERE dedupe_key = ? AND deleted_at IS NULL
                       """,
                       arguments: [key]
                   ) {
                    let existingID = try existingRow.decode(String.self, forColumn: "id")
                    try Self.appendSources(db, memoryID: existingID, sources: draft.sources, at: millis)
                    return try Self.decode(existingRow)
                }

                let id = UUID().uuidString
                try db.execute(
                    sql: """
                    INSERT INTO memories
                        (id, type, title, content, importance, salience, confidence, status,
                         first_seen_at, scope, layer, category, source_kind, epistemic_status,
                         version, dedupe_key, heat, classification_status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, 1, ?, 'warm', 'confirmed', ?, ?)
                    """,
                    arguments: [
                        id, draft.type, draft.title, content, draft.importance,
                        draft.salience, draft.confidence, millis,
                        draft.scope.rawValue, draft.layer, draft.category,
                        draft.sourceKind, draft.epistemicStatus, draft.dedupeKey,
                        millis, millis
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO memory_versions
                        (id, memory_id, version, title, content, change_reason, changed_by, source_kind, created_at)
                    VALUES (?, ?, 1, ?, ?, '初始写入', 'system', ?, ?)
                    """,
                    arguments: [UUID().uuidString, id, draft.title, content, draft.sourceKind, millis]
                )
                try Self.appendSources(db, memoryID: id, sources: draft.sources, at: millis)
                try Self.index(db, memoryID: id, scope: draft.scope, title: draft.title, content: content)

                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM memories WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MemoryError.notFound
                }
                return try Self.decode(row)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    @discardableResult
    public func updateContent(
        id: String,
        title: String,
        content: String,
        changedBy: String,
        reason: String,
        at millis: Int64
    ) async throws -> MemoryRecord {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryError.emptyContent }
        guard Self.validEditors.contains(changedBy) else {
            throw MemoryError.invalidChangedBy(changedBy)
        }

        do {
            return try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM memories WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MemoryError.notFound
                }
                if Int64.fromDatabaseValue(row["deleted_at"]) != nil {
                    throw MemoryError.notFound
                }

                let scopeRaw = try row.decode(String.self, forColumn: "scope")
                let scope = MemoryScope(rawValue: scopeRaw) ?? .shared
                let version = (Int.fromDatabaseValue(row["version"]) ?? 1) + 1

                try db.execute(
                    sql: """
                    UPDATE memories SET title = ?, content = ?, version = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [title, trimmed, version, millis, id]
                )
                try db.execute(
                    sql: """
                    INSERT INTO memory_versions
                        (id, memory_id, version, title, content, change_reason, changed_by, source_kind, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'real_interaction', ?)
                    """,
                    arguments: [UUID().uuidString, id, version, title, trimmed, reason, changedBy, millis]
                )
                try Self.index(db, memoryID: id, scope: scope, title: title, content: trimmed)

                guard let updated = try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM memories WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MemoryError.notFound
                }
                return try Self.decode(updated)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func setScope(id: String, scope: MemoryScope, evidence: String, at millis: Int64) async throws {
        do {
            try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT title, content FROM memories WHERE id = ? AND deleted_at IS NULL",
                    arguments: [id]
                ) else {
                    throw MemoryError.notFound
                }
                try db.execute(
                    sql: """
                    UPDATE memories SET scope = ?, classification_status = 'confirmed',
                           classification_evidence_json = ?, classified_by = 'user', classified_at = ?,
                           updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [scope.rawValue, Self.jsonArray([evidence]), millis, millis, id]
                )
                try Self.index(
                    db,
                    memoryID: id,
                    scope: scope,
                    title: try row.decode(String.self, forColumn: "title"),
                    content: try row.decode(String.self, forColumn: "content")
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func setImportance(
        id: String,
        score: Double,
        source: String,
        reason: String,
        at millis: Int64
    ) async throws {
        let clamped = min(max(score, 0), 1)
        do {
            try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT importance_score, importance_source FROM memories WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MemoryError.notFound
                }
                let fromScore = Double.fromDatabaseValue(row["importance_score"])
                let fromSource = String.fromDatabaseValue(row["importance_source"])

                try db.execute(
                    sql: """
                    UPDATE memories
                    SET importance_score = ?, importance_source = ?, importance_source_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [clamped, source, millis, millis, id]
                )
                // 重要度变更必须留痕：谁改的、为什么改（D12）
                try db.execute(
                    sql: """
                    INSERT INTO memory_importance_history
                        (id, memory_id, from_source, to_source, from_score, to_score,
                         reason, evidence, decided_by, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 'user', ?)
                    """,
                    arguments: [
                        UUID().uuidString, id, fromSource, source, fromScore, clamped,
                        reason, millis
                    ]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func addSource(memoryID: String, source: MemorySourceRef) async throws {
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM memories WHERE id = ?",
                    arguments: [memoryID]
                ) != nil else {
                    throw MemoryError.notFound
                }
                try Self.appendSources(db, memoryID: memoryID, sources: [source], at: source.at ?? 0)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 查询

    public func memory(id: String) async throws -> MemoryRecord? {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM memories WHERE id = ?",
                    arguments: [id]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func sources(memoryID: String) async throws -> [MemorySourceRef] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT source_type, source_id, excerpt, at FROM memory_sources
                    WHERE memory_id = ? ORDER BY created_at ASC, id ASC
                    """,
                    arguments: [memoryID]
                ).map { row in
                    MemorySourceRef(
                        sourceType: try row.decode(String.self, forColumn: "source_type"),
                        sourceID: try row.decode(String.self, forColumn: "source_id"),
                        excerpt: try row.decode(String.self, forColumn: "excerpt"),
                        at: Int64.fromDatabaseValue(row["at"])
                    )
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func memories(
        scope: MemoryScope?,
        layer: String?,
        includeArchived: Bool,
        limit: Int,
        offset: Int
    ) async throws -> [MemoryRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM memories
                    WHERE deleted_at IS NULL
                      AND (? = 1 OR archived_at IS NULL)
                      AND (? IS NULL OR scope = ?)
                      AND (? IS NULL OR layer = ?)
                    ORDER BY COALESCE(importance_score, confidence) DESC, updated_at DESC, id ASC
                    LIMIT ? OFFSET ?
                    """,
                    arguments: [
                        includeArchived ? 1 : 0,
                        scope?.rawValue, scope?.rawValue,
                        layer, layer,
                        min(max(limit, 1), 500), max(offset, 0)
                    ]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func search(query: String, scope: MemoryScope?, limit: Int) async throws -> [MemoryRecord] {
        let tokens = V2Memory.bigram(query)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " AND ")

        do {
            return try await database.dbQueue.read { db in
                let ids = try String.fetchAll(
                    db,
                    sql: """
                    SELECT memory_id FROM memory_fts
                    WHERE memory_fts MATCH ?
                      AND (? IS NULL OR scope = ?)
                    ORDER BY bm25(memory_fts) ASC
                    LIMIT ?
                    """,
                    arguments: [match, scope?.rawValue, scope?.rawValue, min(max(limit, 1), 200)]
                )
                guard !ids.isEmpty else { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM memories
                    WHERE id IN (\(placeholders)) AND deleted_at IS NULL
                    """,
                    arguments: StatementArguments(ids)
                )
                let byID = Dictionary(uniqueKeysWithValues: try rows.map { (try $0.decode(String.self, forColumn: "id"), try Self.decode($0)) })
                return ids.compactMap { byID[$0] }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func versions(memoryID: String) async throws -> [MemoryVersionRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, memory_id, version, title, content, change_reason, changed_by, created_at
                    FROM memory_versions WHERE memory_id = ? ORDER BY version ASC
                    """,
                    arguments: [memoryID]
                ).map { row in
                    MemoryVersionRecord(
                        id: try row.decode(String.self, forColumn: "id"),
                        memoryID: try row.decode(String.self, forColumn: "memory_id"),
                        version: try row.decode(Int.self, forColumn: "version"),
                        title: try row.decode(String.self, forColumn: "title"),
                        content: try row.decode(String.self, forColumn: "content"),
                        changeReason: try row.decode(String.self, forColumn: "change_reason"),
                        changedBy: try row.decode(String.self, forColumn: "changed_by"),
                        createdAt: try row.decode(Int64.self, forColumn: "created_at")
                    )
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 状态

    public func archive(id: String, at millis: Int64) async throws {
        try await updateTimestampColumn(id: id, column: "archived_at", value: millis)
    }

    public func softDelete(id: String, at millis: Int64) async throws {
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM memories WHERE id = ?",
                    arguments: [id]
                ) != nil else {
                    throw MemoryError.notFound
                }
                try db.execute(
                    sql: "UPDATE memories SET deleted_at = COALESCE(deleted_at, ?) WHERE id = ?",
                    arguments: [millis, id]
                )
                try db.execute(sql: "DELETE FROM memory_fts WHERE memory_id = ?", arguments: [id])
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    @discardableResult
    public func softDelete(sourceType: String, sourceID: String, at millis: Int64) async throws -> Int {
        do {
            return try await database.write { db in
                let ids = try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT memory_id FROM memory_sources
                    WHERE source_type = ? AND source_id = ?
                    """,
                    arguments: [sourceType, sourceID]
                )
                var affected = 0
                for id in ids {
                    try db.execute(
                        sql: """
                        UPDATE memories SET deleted_at = ?
                        WHERE id = ? AND deleted_at IS NULL
                        """,
                        arguments: [millis, id]
                    )
                    guard db.changesCount == 1 else { continue }
                    affected += 1
                    try db.execute(sql: "DELETE FROM memory_fts WHERE memory_id = ?", arguments: [id])
                }
                return affected
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func restore(id: String) async throws {
        do {
            try await database.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT scope, title, content FROM memories WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MemoryError.notFound
                }
                try db.execute(
                    sql: "UPDATE memories SET deleted_at = NULL WHERE id = ?",
                    arguments: [id]
                )
                try Self.index(
                    db,
                    memoryID: id,
                    scope: MemoryScope(rawValue: try row.decode(String.self, forColumn: "scope")) ?? .shared,
                    title: try row.decode(String.self, forColumn: "title"),
                    content: try row.decode(String.self, forColumn: "content")
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func count(scope: MemoryScope?) async throws -> Int {
        do {
            return try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT count(*) FROM memories
                    WHERE deleted_at IS NULL AND (? IS NULL OR scope = ?)
                    """,
                    arguments: [scope?.rawValue, scope?.rawValue]
                ) ?? 0
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    @discardableResult
    public func rebuildIndex() async throws -> Int {
        do {
            return try await database.write { db in
                guard try db.tableExists("memory_fts") else { return 0 }
                try db.execute(sql: "DELETE FROM memory_fts")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, scope, title, content FROM memories WHERE deleted_at IS NULL
                    """
                )
                for row in rows {
                    try Self.index(
                        db,
                        memoryID: try row.decode(String.self, forColumn: "id"),
                        scope: MemoryScope(rawValue: try row.decode(String.self, forColumn: "scope")) ?? .shared,
                        title: try row.decode(String.self, forColumn: "title"),
                        content: try row.decode(String.self, forColumn: "content")
                    )
                }
                return rows.count
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 内部

    private func updateTimestampColumn(id: String, column: String, value: Int64) async throws {
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM memories WHERE id = ?",
                    arguments: [id]
                ) != nil else {
                    throw MemoryError.notFound
                }
                try db.execute(
                    sql: "UPDATE memories SET \(column) = ?, updated_at = ? WHERE id = ?",
                    arguments: [value, value, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    private static func appendSources(
        _ db: Database,
        memoryID: String,
        sources: [MemorySourceRef],
        at millis: Int64
    ) throws {
        for source in sources {
            try db.execute(
                sql: """
                INSERT INTO memory_sources (id, memory_id, source_type, source_id, excerpt, at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(memory_id, source_type, source_id) DO NOTHING
                """,
                arguments: [
                    UUID().uuidString, memoryID, source.sourceType, source.sourceID,
                    source.excerpt, source.at ?? millis, millis
                ]
            )
        }
    }

    private static func index(
        _ db: Database,
        memoryID: String,
        scope: MemoryScope,
        title: String,
        content: String
    ) throws {
        guard try db.tableExists("memory_fts") else { return }
        try db.execute(sql: "DELETE FROM memory_fts WHERE memory_id = ?", arguments: [memoryID])
        let merged = (title + "\n" + content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merged.isEmpty else { return }
        try db.execute(
            sql: "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, ?, ?)",
            arguments: [memoryID, scope.rawValue, V2Memory.bigram(merged)]
        )
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func decode(_ row: Row) throws -> MemoryRecord {
        MemoryRecord(
            id: try row.decode(String.self, forColumn: "id"),
            type: try row.decode(String.self, forColumn: "type"),
            title: try row.decode(String.self, forColumn: "title"),
            content: try row.decode(String.self, forColumn: "content"),
            importance: try row.decode(String.self, forColumn: "importance"),
            importanceScore: Double.fromDatabaseValue(row["importance_score"]),
            importanceSource: try row.decode(String.self, forColumn: "importance_source"),
            salience: Double.fromDatabaseValue(row["salience"]) ?? 0.5,
            confidence: Double.fromDatabaseValue(row["confidence"]) ?? 0.5,
            status: try row.decode(String.self, forColumn: "status"),
            scope: MemoryScope(rawValue: try row.decode(String.self, forColumn: "scope")) ?? .shared,
            layer: try row.decode(String.self, forColumn: "layer"),
            category: try row.decode(String.self, forColumn: "category"),
            sourceKind: try row.decode(String.self, forColumn: "source_kind"),
            epistemicStatus: try row.decode(String.self, forColumn: "epistemic_status"),
            version: Int.fromDatabaseValue(row["version"]) ?? 1,
            dedupeKey: String.fromDatabaseValue(row["dedupe_key"]),
            heat: try row.decode(String.self, forColumn: "heat"),
            classificationStatus: try row.decode(String.self, forColumn: "classification_status"),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            updatedAt: try row.decode(Int64.self, forColumn: "updated_at"),
            firstSeenAt: try row.decode(Int64.self, forColumn: "first_seen_at"),
            lastRecalledAt: Int64.fromDatabaseValue(row["last_recalled_at"]),
            recallCount: Int.fromDatabaseValue(row["recall_count"]) ?? 0,
            archivedAt: Int64.fromDatabaseValue(row["archived_at"]),
            deletedAt: Int64.fromDatabaseValue(row["deleted_at"])
        )
    }
}
