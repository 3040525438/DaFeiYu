import Foundation
import GRDB
import DFCore

// MARK: - 附件

/// 附件元数据仓储。文件本体仍由 `AttachmentStore` 管理，这里只管"库里那一行"。
public struct GRDBAttachmentRepository: AttachmentRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let columns = """
    id, sha256, kind, rel_path, byte_size, mime, width, height, duration_ms,
    thumbnail_rel_path, created_at, deleted_at
    """

    public func ensure(_ attachment: NewAttachment) async throws -> AttachmentRecord {
        do {
            return try await database.write { db in
                if let existing = try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM attachments WHERE sha256 = ?",
                    arguments: [attachment.sha256]
                ) {
                    return try Self.decode(existing)
                }
                let id = UUID().uuidString
                try db.execute(
                    sql: """
                    INSERT INTO attachments (id, sha256, kind, rel_path, byte_size, mime, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id, attachment.sha256, attachment.kind, attachment.relPath,
                        attachment.byteSize, attachment.mime, attachment.createdAt
                    ]
                )
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM attachments WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw MultimodalError.notFound
                }
                return try Self.decode(row)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func attachment(id: String) async throws -> AttachmentRecord? {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM attachments WHERE id = ?",
                    arguments: [id]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func attachments(inMessage messageID: String, includeDeleted: Bool) async throws -> [AttachmentRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT a.id, a.sha256, a.kind, a.rel_path, a.byte_size, a.mime,
                           a.width, a.height, a.duration_ms, a.thumbnail_rel_path,
                           a.created_at, a.deleted_at
                    FROM attachments a
                    JOIN message_attachments ma ON ma.attachment_id = a.id
                    WHERE ma.message_id = ?
                      AND (? = 1 OR a.deleted_at IS NULL)
                    ORDER BY ma.sort ASC, a.id ASC
                    """,
                    arguments: [messageID, includeDeleted ? 1 : 0]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func messageIDs(usingAttachment id: String) async throws -> [String] {
        do {
            return try await database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT message_id FROM message_attachments
                    WHERE attachment_id = ? ORDER BY message_id ASC
                    """,
                    arguments: [id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func unreferenced(before millis: Int64, limit: Int) async throws -> [AttachmentRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM attachments a
                    WHERE a.deleted_at IS NULL
                      AND a.created_at < ?
                      AND NOT EXISTS (
                          SELECT 1 FROM message_attachments ma WHERE ma.attachment_id = a.id
                      )
                    ORDER BY a.created_at ASC
                    LIMIT ?
                    """,
                    arguments: [millis, min(max(limit, 1), 500)]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func setMetrics(
        id: String,
        width: Int?,
        height: Int?,
        durationMs: Int?,
        thumbnailRelPath: String?
    ) async throws {
        do {
            try await database.write { db in
                guard try Self.exists(db, id: id) else { throw MultimodalError.notFound }
                // COALESCE：只覆盖本次给出的值，nil 表示"这次没测到"，不能把已有值擦掉
                try db.execute(
                    sql: """
                    UPDATE attachments
                    SET width = COALESCE(?, width),
                        height = COALESCE(?, height),
                        duration_ms = COALESCE(?, duration_ms),
                        thumbnail_rel_path = COALESCE(?, thumbnail_rel_path)
                    WHERE id = ?
                    """,
                    arguments: [width, height, durationMs, thumbnailRelPath, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func link(messageID: String, attachmentID: String, sort: Int) async throws {
        do {
            try await database.write { db in
                guard try Self.exists(db, id: attachmentID) else { throw MultimodalError.notFound }
                try db.execute(
                    sql: """
                    INSERT INTO message_attachments (message_id, attachment_id, sort)
                    VALUES (?, ?, ?)
                    ON CONFLICT(message_id, attachment_id) DO UPDATE SET sort = excluded.sort
                    """,
                    arguments: [messageID, attachmentID, sort]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func unlink(messageID: String, attachmentID: String) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM message_attachments WHERE message_id = ? AND attachment_id = ?",
                    arguments: [messageID, attachmentID]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func softDelete(id: String, reason: String?, at millis: Int64) async throws {
        do {
            try await database.write { db in
                guard try Self.exists(db, id: id) else { throw MultimodalError.notFound }
                // 已软删时保持首次删除时间，不刷新
                try db.execute(
                    sql: """
                    UPDATE attachments
                    SET deleted_at = COALESCE(deleted_at, ?), deleted_reason = COALESCE(?, deleted_reason)
                    WHERE id = ?
                    """,
                    arguments: [millis, reason, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func restore(id: String) async throws {
        do {
            try await database.write { db in
                guard try Self.exists(db, id: id) else { throw MultimodalError.notFound }
                try db.execute(
                    sql: "UPDATE attachments SET deleted_at = NULL, deleted_reason = NULL WHERE id = ?",
                    arguments: [id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 内部

    private static func exists(_ db: Database, id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT 1 FROM attachments WHERE id = ?", arguments: [id]) != nil
    }

    private static func decode(_ row: Row) throws -> AttachmentRecord {
        AttachmentRecord(
            id: try row.decode(String.self, forColumn: "id"),
            sha256: try row.decode(String.self, forColumn: "sha256"),
            kind: try row.decode(String.self, forColumn: "kind"),
            relPath: try row.decode(String.self, forColumn: "rel_path"),
            byteSize: try row.decode(Int64.self, forColumn: "byte_size"),
            mime: try row.decode(String.self, forColumn: "mime"),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            width: Int.fromDatabaseValue(row["width"]),
            height: Int.fromDatabaseValue(row["height"]),
            durationMs: Int.fromDatabaseValue(row["duration_ms"]),
            thumbnailRelPath: String.fromDatabaseValue(row["thumbnail_rel_path"]),
            deletedAt: Int64.fromDatabaseValue(row["deleted_at"])
        )
    }
}

// MARK: - OCR / 转写

public struct GRDBAttachmentTextRepository: AttachmentTextRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func upsert(
        attachmentID: String,
        kind: AttachmentTextKind,
        text: String,
        language: String?,
        engine: String,
        confidence: Double?,
        at millis: Int64
    ) async throws -> AttachmentTextRecord? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await remove(attachmentID: attachmentID, kind: kind)
            return nil
        }

        do {
            return try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM attachments WHERE id = ?",
                    arguments: [attachmentID]
                ) != nil else {
                    throw MultimodalError.notFound
                }

                try db.execute(
                    sql: """
                    INSERT INTO attachment_texts
                        (id, attachment_id, kind, text, language, engine, confidence, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(attachment_id, kind) DO UPDATE SET
                        text = excluded.text,
                        language = excluded.language,
                        engine = excluded.engine,
                        confidence = excluded.confidence,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        UUID().uuidString, attachmentID, kind.rawValue, trimmed,
                        language, engine, confidence, millis, millis
                    ]
                )
                try Self.rebuildIndex(db, attachmentID: attachmentID)
                return try Self.fetch(db, attachmentID: attachmentID, kind: kind)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func text(attachmentID: String, kind: AttachmentTextKind) async throws -> AttachmentTextRecord? {
        do {
            return try await database.dbQueue.read { db in
                try Self.fetch(db, attachmentID: attachmentID, kind: kind)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func texts(attachmentID: String) async throws -> [AttachmentTextRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT attachment_id, kind, text, language, engine, confidence, created_at, updated_at
                    FROM attachment_texts WHERE attachment_id = ? ORDER BY kind ASC
                    """,
                    arguments: [attachmentID]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func remove(attachmentID: String, kind: AttachmentTextKind) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM attachment_texts WHERE attachment_id = ? AND kind = ?",
                    arguments: [attachmentID, kind.rawValue]
                )
                try Self.rebuildIndex(db, attachmentID: attachmentID)
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
        let clamped = min(max(limit, 1), 100)

        do {
            return try await database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT attachment_id FROM attachment_text_fts
                    WHERE attachment_text_fts MATCH ?
                      AND attachment_id IN (
                          SELECT id FROM attachments WHERE deleted_at IS NULL
                      )
                    ORDER BY bm25(attachment_text_fts) ASC
                    LIMIT ?
                    """,
                    arguments: [match, clamped]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 内部

    /// 同一附件的 OCR + 转写合并成一行索引，避免"只搜到其中一种"
    static func rebuildIndex(_ db: Database, attachmentID: String) throws {
        guard try db.tableExists("attachment_text_fts") else { return }
        try db.execute(
            sql: "DELETE FROM attachment_text_fts WHERE attachment_id = ?",
            arguments: [attachmentID]
        )
        let parts = try String.fetchAll(
            db,
            sql: "SELECT text FROM attachment_texts WHERE attachment_id = ? ORDER BY kind ASC",
            arguments: [attachmentID]
        )
        let merged = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merged.isEmpty else { return }
        try db.execute(
            sql: "INSERT INTO attachment_text_fts (attachment_id, text_bigram) VALUES (?, ?)",
            arguments: [attachmentID, V2Memory.bigram(merged)]
        )
    }

    private static func fetch(_ db: Database, attachmentID: String, kind: AttachmentTextKind) throws -> AttachmentTextRecord? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT attachment_id, kind, text, language, engine, confidence, created_at, updated_at
            FROM attachment_texts WHERE attachment_id = ? AND kind = ?
            """,
            arguments: [attachmentID, kind.rawValue]
        ).map(decode)
    }

    private static func decode(_ row: Row) throws -> AttachmentTextRecord {
        AttachmentTextRecord(
            attachmentID: try row.decode(String.self, forColumn: "attachment_id"),
            kind: AttachmentTextKind(rawValue: try row.decode(String.self, forColumn: "kind")) ?? .ocr,
            text: try row.decode(String.self, forColumn: "text"),
            language: String.fromDatabaseValue(row["language"]),
            engine: try row.decode(String.self, forColumn: "engine"),
            confidence: Double.fromDatabaseValue(row["confidence"]),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            updatedAt: try row.decode(Int64.self, forColumn: "updated_at")
        )
    }
}

// MARK: - 多图理解

public struct GRDBImageAnalysisRepository: ImageAnalysisRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let statuses: Set<String> = ["pending", "running", "done", "failed"]

    public func create(
        conversationID: String?,
        messageID: String?,
        attachmentIDs: [String],
        prompt: String,
        modelConfigID: String?,
        at millis: Int64
    ) async throws -> ImageAnalysisRecord {
        guard !attachmentIDs.isEmpty else { throw MultimodalError.emptyAttachments }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MultimodalError.emptyPrompt }
        guard let json = Self.encodeIDs(attachmentIDs) else {
            throw DFError.database("附件列表序列化失败")
        }

        let id = UUID().uuidString
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO image_analyses
                        (id, conversation_id, message_id, attachment_ids_json, prompt,
                         result, model_config_id, status, created_at)
                    VALUES (?, ?, ?, ?, ?, '', ?, 'pending', ?)
                    """,
                    arguments: [id, conversationID, messageID, json, trimmed, modelConfigID, millis]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }

        guard let record = try await analysis(id: id) else { throw MultimodalError.notFound }
        return record
    }

    public func finish(id: String, result: String, status: String, at millis: Int64) async throws {
        guard Self.statuses.contains(status) else { throw MultimodalError.invalidStatus(status) }
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM image_analyses WHERE id = ?",
                    arguments: [id]
                ) != nil else {
                    throw MultimodalError.notFound
                }
                try db.execute(
                    sql: """
                    UPDATE image_analyses
                    SET result = ?, status = ?, finished_at = ?
                    WHERE id = ?
                    """,
                    arguments: [result, status, millis, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func analyses(messageID: String) async throws -> [ImageAnalysisRecord] {
        try await list(
            sql: "\(Self.select) WHERE message_id = ? ORDER BY created_at ASC, id ASC",
            arguments: [messageID]
        )
    }

    public func analyses(conversationID: String, limit: Int) async throws -> [ImageAnalysisRecord] {
        try await list(
            sql: "\(Self.select) WHERE conversation_id = ? ORDER BY created_at DESC, id DESC LIMIT ?",
            arguments: [conversationID, min(max(limit, 1), 200)]
        )
    }

    public func analysis(id: String) async throws -> ImageAnalysisRecord? {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchOne(db, sql: "\(Self.select) WHERE id = ?", arguments: [id]).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 内部

    private static let select = """
    SELECT id, conversation_id, message_id, attachment_ids_json, prompt, result,
           model_config_id, status, created_at, finished_at
    FROM image_analyses
    """

    private func list(sql: String, arguments: StatementArguments) async throws -> [ImageAnalysisRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    private static func encodeIDs(_ ids: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ row: Row) throws -> ImageAnalysisRecord {
        let raw = try row.decode(String.self, forColumn: "attachment_ids_json")
        let ids = (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
        return ImageAnalysisRecord(
            id: try row.decode(String.self, forColumn: "id"),
            conversationID: String.fromDatabaseValue(row["conversation_id"]),
            messageID: String.fromDatabaseValue(row["message_id"]),
            attachmentIDs: ids,
            prompt: try row.decode(String.self, forColumn: "prompt"),
            result: try row.decode(String.self, forColumn: "result"),
            modelConfigID: String.fromDatabaseValue(row["model_config_id"]),
            status: try row.decode(String.self, forColumn: "status"),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            finishedAt: Int64.fromDatabaseValue(row["finished_at"])
        )
    }
}
