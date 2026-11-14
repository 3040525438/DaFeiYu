import Foundation
import GRDB
import DFCore

/// 每日日记仓储（W6-7）。
///
/// 规则：
/// - 一天一篇（软删后允许重建）；
/// - 每次写入都追加一条全量版本快照，历史内容不可被覆盖；
/// - 正文同步 `diary_fts`，供全局检索（D25）。
public struct GRDBDiaryRepository: DiaryRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let columns = """
    id, entry_date, title, content, mood_code, source, generated_by, is_user_edited,
    memory_id, created_at, updated_at, deleted_at
    """

    public func upsert(_ request: DiaryUpsert, at millis: Int64) async throws -> DiaryEntry {
        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw DiaryError.emptyContent }
        guard Self.isValidDate(request.entryDate) else {
            throw DiaryError.invalidDate(request.entryDate)
        }
        guard ["user", "ai", "migration"].contains(request.changedBy) else {
            throw DiaryError.invalidEditor(request.changedBy)
        }

        do {
            return try await database.write { db in
                let existing = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM diary_entries
                    WHERE entry_date = ? AND deleted_at IS NULL
                    """,
                    arguments: [request.entryDate]
                )

                let diaryID: String
                if let existing {
                    diaryID = try existing.decode(String.self, forColumn: "id")
                    try db.execute(
                        sql: """
                        UPDATE diary_entries
                        SET title = ?, content = ?, mood_code = ?, source = ?, generated_by = ?,
                            is_user_edited = ?, memory_id = ?, updated_at = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            request.title, content, request.moodCode, request.source,
                            request.generatedBy, request.isUserEdited ? 1 : 0,
                            request.memoryID, millis, diaryID
                        ]
                    )
                } else {
                    diaryID = UUID().uuidString
                    try db.execute(
                        sql: """
                        INSERT INTO diary_entries
                            (id, entry_date, title, content, mood_code, source, generated_by,
                             is_user_edited, memory_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            diaryID, request.entryDate, request.title, content, request.moodCode,
                            request.source, request.generatedBy, request.isUserEdited ? 1 : 0,
                            request.memoryID, millis, millis
                        ]
                    )
                }

                let nextVersion = (try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(version), 0) FROM diary_entry_versions WHERE diary_id = ?",
                    arguments: [diaryID]
                ) ?? 0) + 1

                try db.execute(
                    sql: """
                    INSERT INTO diary_entry_versions
                        (id, diary_id, version, title, content, change_reason, changed_by, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, diaryID, nextVersion, request.title, content,
                        request.changeReason, request.changedBy, millis
                    ]
                )

                try Self.index(db, diaryID: diaryID, title: request.title, content: content)

                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM diary_entries WHERE id = ?",
                    arguments: [diaryID]
                ) else {
                    throw DiaryError.notFound
                }
                return try Self.decode(row)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func entry(id: String) async throws -> DiaryEntry? {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM diary_entries WHERE id = ?",
                    arguments: [id]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func entry(date: String) async throws -> DiaryEntry? {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM diary_entries
                    WHERE entry_date = ? AND deleted_at IS NULL
                    """,
                    arguments: [date]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func entries(from startDate: String, to endDate: String, limit: Int) async throws -> [DiaryEntry] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM diary_entries
                    WHERE deleted_at IS NULL AND entry_date >= ? AND entry_date <= ?
                    ORDER BY entry_date DESC
                    LIMIT ?
                    """,
                    arguments: [startDate, endDate, min(max(limit, 1), 365)]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func versions(diaryID: String) async throws -> [DiaryVersion] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, diary_id, version, title, content, change_reason, changed_by, created_at
                    FROM diary_entry_versions WHERE diary_id = ? ORDER BY version ASC
                    """,
                    arguments: [diaryID]
                ).map { row in
                    DiaryVersion(
                        id: try row.decode(String.self, forColumn: "id"),
                        diaryID: try row.decode(String.self, forColumn: "diary_id"),
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

    public func softDelete(id: String, at millis: Int64) async throws {
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM diary_entries WHERE id = ?",
                    arguments: [id]
                ) != nil else {
                    throw DiaryError.notFound
                }
                try db.execute(
                    sql: "UPDATE diary_entries SET deleted_at = COALESCE(deleted_at, ?) WHERE id = ?",
                    arguments: [millis, id]
                )
                if try db.tableExists("diary_fts") {
                    try db.execute(sql: "DELETE FROM diary_fts WHERE diary_id = ?", arguments: [id])
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func search(query: String, limit: Int) async throws -> [String] {
        let tokens = V2Memory.bigram(query)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " AND ")

        do {
            return try await database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT diary_id FROM diary_fts
                    WHERE diary_fts MATCH ?
                      AND diary_id IN (SELECT id FROM diary_entries WHERE deleted_at IS NULL)
                    ORDER BY bm25(diary_fts) ASC
                    LIMIT ?
                    """,
                    arguments: [match, min(max(limit, 1), 100)]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    @discardableResult
    public func rebuildIndex() async throws -> Int {
        do {
            return try await database.write { db in
                guard try db.tableExists("diary_fts") else { return 0 }
                try db.execute(sql: "DELETE FROM diary_fts")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, title, content FROM diary_entries WHERE deleted_at IS NULL"
                )
                for row in rows {
                    try Self.index(
                        db,
                        diaryID: try row.decode(String.self, forColumn: "id"),
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

    private static func index(_ db: Database, diaryID: String, title: String, content: String) throws {
        guard try db.tableExists("diary_fts") else { return }
        try db.execute(sql: "DELETE FROM diary_fts WHERE diary_id = ?", arguments: [diaryID])
        let merged = (title + "\n" + content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merged.isEmpty else { return }
        try db.execute(
            sql: "INSERT INTO diary_fts (diary_id, text_bigram) VALUES (?, ?)",
            arguments: [diaryID, V2Memory.bigram(merged)]
        )
    }

    /// 严格 `yyyy-MM-dd`：长度、分隔符、数值范围都要对，避免脏日期污染"一天一篇"约束
    static func isValidDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else {
            return false
        }
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return false }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day
    }

    private static func decode(_ row: Row) throws -> DiaryEntry {
        DiaryEntry(
            id: try row.decode(String.self, forColumn: "id"),
            entryDate: try row.decode(String.self, forColumn: "entry_date"),
            title: try row.decode(String.self, forColumn: "title"),
            content: try row.decode(String.self, forColumn: "content"),
            moodCode: String.fromDatabaseValue(row["mood_code"]),
            source: try row.decode(String.self, forColumn: "source"),
            generatedBy: String.fromDatabaseValue(row["generated_by"]),
            isUserEdited: (Int.fromDatabaseValue(row["is_user_edited"]) ?? 0) != 0,
            memoryID: String.fromDatabaseValue(row["memory_id"]),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            updatedAt: try row.decode(Int64.self, forColumn: "updated_at"),
            deletedAt: Int64.fromDatabaseValue(row["deleted_at"])
        )
    }
}
