import Foundation
import GRDB
import DFCore

public struct GRDBModelConfigRepository: ModelConfigRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func all() async throws -> [ModelConfig] {
        do {
            return try await database.dbQueue.read { db in
                try ModelConfig
                    .order(Column("created_at").asc)
                    .fetchAll(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func defaultConfig() async throws -> ModelConfig? {
        do {
            return try await database.dbQueue.read { db in
                try ModelConfig
                    .filter(Column("is_default") == true)
                    .order(Column("updated_at").desc)
                    .fetchOne(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func config(id: String) async throws -> ModelConfig? {
        do {
            return try await database.dbQueue.read { db in
                try ModelConfig.fetchOne(db, key: id)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func save(_ config: ModelConfig) async throws {
        do {
            try await database.dbQueue.write { db in
                var record = config
                record.updatedAt = Clock.nowMillis()
                // is_default 只由 makeDefault 修改，避免"编辑配置"意外改变默认项
                if let existing = try ModelConfig.fetchOne(db, key: record.id) {
                    record.isDefault = existing.isDefault
                }
                try record.save(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func delete(id: String) async throws {
        do {
            try await database.dbQueue.write { db in
                _ = try ModelConfig.deleteOne(db, key: id)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func makeDefault(id: String) async throws {
        do {
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE model_configs SET is_default = 0")
                try db.execute(
                    sql: "UPDATE model_configs SET is_default = 1, updated_at = ? WHERE id = ?",
                    arguments: [Clock.nowMillis(), id]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}

public struct GRDBSettingsRepository: SettingsRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func string(for key: String) async throws -> String? {
        do {
            return try await database.dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func set(_ value: String, for key: String) async throws {
        do {
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO settings(key, value) VALUES(?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}
