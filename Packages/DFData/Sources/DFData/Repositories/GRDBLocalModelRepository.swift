import Foundation
import GRDB
import DFCore

/// 本地模型注册表（W5）。
///
/// 只存元数据与状态；模型文件本体由下载器写到应用支持目录，路径记录在 `file_rel_path`。
public struct GRDBLocalModelRepository: LocalModelRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let columns = """
    id, name, family, quantization, format, file_rel_path, byte_size, sha256,
    source_url, license, version, context_length, supports_vision, supports_asr,
    supports_tools, status, downloaded_bytes, wifi_only, last_verified_at,
    created_at, updated_at
    """

    public func save(_ model: LocalModelRecord) async throws -> LocalModelRecord {
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LocalModelError.emptyName }
        guard LocalModelStatus.allCases.contains(model.status) else {
            throw LocalModelError.invalidStatus(model.status.rawValue)
        }
        guard model.downloadedBytes >= 0, model.downloadedBytes <= max(model.byteSize, 0) else {
            throw LocalModelError.invalidProgress
        }

        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO local_models
                        (id, name, family, quantization, format, file_rel_path, byte_size, sha256,
                         source_url, license, version, context_length, supports_vision, supports_asr,
                         supports_tools, status, downloaded_bytes, wifi_only, last_verified_at,
                         created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        family = excluded.family,
                        quantization = excluded.quantization,
                        format = excluded.format,
                        file_rel_path = excluded.file_rel_path,
                        byte_size = excluded.byte_size,
                        sha256 = excluded.sha256,
                        source_url = excluded.source_url,
                        license = excluded.license,
                        version = excluded.version,
                        context_length = excluded.context_length,
                        supports_vision = excluded.supports_vision,
                        supports_asr = excluded.supports_asr,
                        supports_tools = excluded.supports_tools,
                        status = excluded.status,
                        downloaded_bytes = excluded.downloaded_bytes,
                        wifi_only = excluded.wifi_only,
                        last_verified_at = excluded.last_verified_at,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        model.id, name, model.family, model.quantization, model.format,
                        model.fileRelPath, model.byteSize, model.sha256, model.sourceURL,
                        model.license, model.version, model.contextLength,
                        model.supportsVision ? 1 : 0, model.supportsASR ? 1 : 0,
                        model.supportsTools ? 1 : 0, model.status.rawValue,
                        model.downloadedBytes, model.wifiOnly ? 1 : 0,
                        model.lastVerifiedAt, model.createdAt, model.updatedAt
                    ]
                )
            }
        } catch let error as DatabaseError {
            // sha256 唯一索引冲突：说明同一文件已登记过，不能静默覆盖
            if (error.message ?? "").contains("local_models.sha256") {
                throw DFError.database("该模型文件已登记：\(model.sha256 ?? "")")
            }
            throw DFError.database(error.message ?? "数据库操作失败")
        } catch {
            throw GRDBErrorMapper.map(error)
        }

        guard let saved = try await self.model(id: model.id) else { throw LocalModelError.notFound }
        return saved
    }

    public func model(id: String) async throws -> LocalModelRecord? {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \(Self.columns) FROM local_models WHERE id = ?",
                    arguments: [id]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func all() async throws -> [LocalModelRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT \(Self.columns) FROM local_models ORDER BY updated_at DESC, id ASC"
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func models(status: LocalModelStatus) async throws -> [LocalModelRecord] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(Self.columns) FROM local_models
                    WHERE status = ? ORDER BY updated_at DESC, id ASC
                    """,
                    arguments: [status.rawValue]
                ).map(Self.decode)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func delete(id: String) async throws {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM local_models WHERE id = ?", arguments: [id])
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func updateDownload(
        id: String,
        status: LocalModelStatus,
        downloadedBytes: Int64,
        at millis: Int64
    ) async throws {
        do {
            try await database.write { db in
                guard let size = try Int64.fetchOne(
                    db,
                    sql: "SELECT byte_size FROM local_models WHERE id = ?",
                    arguments: [id]
                ) else {
                    throw LocalModelError.notFound
                }
                let clamped = min(max(downloadedBytes, 0), max(size, 0))
                try db.execute(
                    sql: """
                    UPDATE local_models
                    SET status = ?, downloaded_bytes = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [status.rawValue, clamped, millis, id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func recordContextProbe(id: String, contextTokens: Int, elapsedMs: Int?, at millis: Int64) async throws {
        guard contextTokens > 0 else { throw LocalModelError.invalidProgress }
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM local_models WHERE id = ?",
                    arguments: [id]
                ) != nil else {
                    throw LocalModelError.notFound
                }
                try db.execute(
                    sql: """
                    UPDATE local_models SET context_length = ?, updated_at = ? WHERE id = ?
                    """,
                    arguments: [contextTokens, millis, id]
                )
                try db.execute(
                    sql: """
                    INSERT INTO model_runtime_events
                        (id, model_id, kind, detail, context_tokens, elapsed_ms, created_at)
                    VALUES (?, ?, 'context_probe', '', ?, ?, ?)
                    """,
                    arguments: [UUID().uuidString, id, contextTokens, elapsedMs, millis]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func markVerified(id: String, sha256: String, at millis: Int64) async throws {
        do {
            try await database.write { db in
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT 1 FROM local_models WHERE id = ?",
                    arguments: [id]
                ) != nil else {
                    throw LocalModelError.notFound
                }
                try db.execute(
                    sql: """
                    UPDATE local_models SET sha256 = ?, last_verified_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    arguments: [sha256, millis, millis, id]
                )
            }
        } catch let error as DatabaseError {
            if (error.message ?? "").contains("local_models.sha256") {
                throw DFError.database("该校验和已登记到其他模型：\(sha256)")
            }
            throw DFError.database(error.message ?? "数据库操作失败")
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func recordEvent(
        modelID: String?,
        kind: String,
        detail: String,
        contextTokens: Int?,
        elapsedMs: Int?,
        at millis: Int64
    ) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO model_runtime_events
                        (id, model_id, kind, detail, context_tokens, elapsed_ms, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [UUID().uuidString, modelID, kind, detail, contextTokens, elapsedMs, millis]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func events(modelID: String, limit: Int) async throws -> [ModelRuntimeEvent] {
        do {
            return try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, model_id, kind, detail, context_tokens, elapsed_ms, created_at
                    FROM model_runtime_events
                    WHERE model_id = ?
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [modelID, min(max(limit, 1), 200)]
                ).map(Self.decodeEvent)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func totalBytes() async throws -> Int64 {
        do {
            return try await database.dbQueue.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(byte_size), 0) FROM local_models WHERE status = 'ready'"
                ) ?? 0
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 内部

    private static func decode(_ row: Row) throws -> LocalModelRecord {
        LocalModelRecord(
            id: try row.decode(String.self, forColumn: "id"),
            name: try row.decode(String.self, forColumn: "name"),
            family: try row.decode(String.self, forColumn: "family"),
            quantization: try row.decode(String.self, forColumn: "quantization"),
            format: try row.decode(String.self, forColumn: "format"),
            fileRelPath: try row.decode(String.self, forColumn: "file_rel_path"),
            byteSize: try row.decode(Int64.self, forColumn: "byte_size"),
            sha256: String.fromDatabaseValue(row["sha256"]),
            sourceURL: String.fromDatabaseValue(row["source_url"]),
            license: String.fromDatabaseValue(row["license"]),
            version: try row.decode(String.self, forColumn: "version"),
            contextLength: Int.fromDatabaseValue(row["context_length"]),
            supportsVision: (Int.fromDatabaseValue(row["supports_vision"]) ?? 0) != 0,
            supportsASR: (Int.fromDatabaseValue(row["supports_asr"]) ?? 0) != 0,
            supportsTools: (Int.fromDatabaseValue(row["supports_tools"]) ?? 0) != 0,
            status: LocalModelStatus(rawValue: try row.decode(String.self, forColumn: "status")) ?? .notDownloaded,
            downloadedBytes: try row.decode(Int64.self, forColumn: "downloaded_bytes"),
            wifiOnly: (Int.fromDatabaseValue(row["wifi_only"]) ?? 1) != 0,
            lastVerifiedAt: Int64.fromDatabaseValue(row["last_verified_at"]),
            createdAt: try row.decode(Int64.self, forColumn: "created_at"),
            updatedAt: try row.decode(Int64.self, forColumn: "updated_at")
        )
    }

    private static func decodeEvent(_ row: Row) throws -> ModelRuntimeEvent {
        ModelRuntimeEvent(
            id: try row.decode(String.self, forColumn: "id"),
            modelID: String.fromDatabaseValue(row["model_id"]),
            kind: try row.decode(String.self, forColumn: "kind"),
            detail: try row.decode(String.self, forColumn: "detail"),
            contextTokens: Int.fromDatabaseValue(row["context_tokens"]),
            elapsedMs: Int.fromDatabaseValue(row["elapsed_ms"]),
            createdAt: try row.decode(Int64.self, forColumn: "created_at")
        )
    }
}
