import XCTest
import GRDB
import DFCore
@testable import DFData

/// 迁移安全测试：FTS5 行为探测 + 迁移失败安全降级 + 用户触发重试（T17–T21）
final class MigrationSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFSafe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 辅助

    /// 构造只跑到 v1_phase1 的库（关闭外键，便于构造历史数据）
    private func makeV1Queue(_ name: String) throws -> DatabaseQueue {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(
            path: dir.appendingPathComponent("db.sqlite").path,
            configuration: configuration
        )
        try Migrations.makeMigrator(upTo: .v1_phase1).migrate(queue)
        return queue
    }

    // MARK: - T17 FTS5 行为探测成功

    func testT17_FTS5ProbeSucceedsAndIsRepeatable() throws {
        // 真实执行：建表 → 插入 → MATCH 命中 → 误命中为 0 → DROP → 无残留
        try MemoryFTS5Probe().verify()
        // 可重复执行，说明清理干净（否则第二次建表会因重名失败）
        try MemoryFTS5Probe().verify()
    }

    // MARK: - T18 探测不污染业务数据库

    func testT18_ProbeLeavesNoTraceInBusinessDatabase() throws {
        let database = try AppDatabase(
            paths: DatabasePaths(root: root.appendingPathComponent("t18", isDirectory: true))
        )

        func objectSnapshot() throws -> [String] {
            try database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT type || ':' || name FROM sqlite_master ORDER BY name"
                )
            }
        }

        let objectsBefore = try objectSnapshot()
        let ledgerBefore = try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations") ?? -1
        }

        try MemoryFTS5Probe().verify()
        try MemoryFTS5Probe().verify()

        XCTAssertEqual(try objectSnapshot(), objectsBefore, "探测不得在业务库留下任何对象")
        XCTAssertFalse(objectsBefore.contains { $0.contains("fts5_probe") })
        XCTAssertEqual(
            try database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations")
            },
            ledgerBefore,
            "探测不得改变迁移台账"
        )
        XCTAssertEqual(database.currentSchemaVersion, Migrations.latest.rawValue)
        XCTAssertFalse(database.isReadOnly)
    }

    // MARK: - T19 FTS5 不可用时阻断迁移并整体回滚

    func testT19_UnavailableFTS5BlocksMigrationAndRollsBack() throws {
        struct FailingProbe: FTS5Probing {
            func verify() throws {
                throw DFError.unsupported("注入：FTS5 不可用")
            }
        }

        let queue = try makeV1Queue("t19")

        XCTAssertThrowsError(
            try queue.write { db in
                try V2Memory.migrate(db, probe: FailingProbe())
            }
        ) { error in
            XCTAssertTrue("\(error)".contains("FTS5"), "错误信息必须指出 FTS5 不可用，实际：\(error)")
        }

        try queue.read { db in
            let created = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE name IN ('schema_meta','memory_scopes','memory_fts')"
            )
            XCTAssertEqual(created, 0, "探测失败时不得留下任何 v2 结构")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_table_info('memories')"),
                13,
                "memories 必须仍是 13 列"
            )
        }
    }

    // MARK: - T20 迁移失败 → 安全只读降级（不抛错、不半迁移）

    func testT20_MigrationFailureDegradesToSafeReadOnlyState() async throws {
        let paths = DatabasePaths(root: root.appendingPathComponent("t20", isDirectory: true))
        let counter = AttemptCounter()
        let database = try AppDatabase(paths: paths, makeMigrator: {
            counter.value += 1
            return makeFailingMigrator()
        })

        // 不抛错、不崩溃：进入明确的迁移失败状态
        XCTAssertNotNil(database.migrationFailureReason)
        XCTAssertTrue(database.isReadOnly)
        XCTAssertEqual(database.currentSchemaVersion, "v1_phase1")
        XCTAssertEqual(counter.value, 1, "启动时只尝试一次，不得静默反复重试")

        // 台账与结构保持 v1，无半迁移产物
        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name = 'schema_meta'"),
                0
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_table_info('memories')"), 13)
        }

        // 统一写入口被拦截
        XCTAssertThrowsError(try database.assertWritable())
        do {
            try await database.write { db in
                try db.execute(sql: "INSERT INTO settings(key, value) VALUES('probe', 'blocked')")
            }
            XCTFail("迁移失败状态必须拒绝 write")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不可写入"), "实际：\(error)")
        }

        // 仓储写入口同样被拦截
        let settings = GRDBSettingsRepository(database: database)
        do {
            try await settings.set("blocked", for: "probe")
            XCTFail("迁移失败状态必须拒绝仓储写入")
        } catch {
            // 预期
        }

        // 被拒绝的写入没有落地
        let stored = try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'probe'")
        }
        XCTAssertNil(stored)
    }

    // MARK: - T21 用户触发重试 → 恢复可写（且不重复迁移）

    func testT21_UserTriggeredRetryRestoresWritableState() async throws {
        let paths = DatabasePaths(root: root.appendingPathComponent("t21", isDirectory: true))
        let counter = AttemptCounter()
        let database = try AppDatabase(paths: paths, makeMigrator: {
            counter.value += 1
            return counter.value == 1 ? makeFailingMigrator() : Migrations.migrator
        })

        XCTAssertTrue(database.isReadOnly)
        XCTAssertEqual(counter.value, 1)

        // 只有显式调用才会重试
        try await database.retryMigration()

        XCTAssertFalse(database.isReadOnly)
        XCTAssertNil(database.migrationFailureReason)
        XCTAssertEqual(database.currentSchemaVersion, Migrations.latest.rawValue)
        XCTAssertEqual(counter.value, 2, "重试只执行一次")

        // 重试成功后恢复读写
        try await database.write { db in
            try db.execute(sql: "INSERT INTO settings(key, value) VALUES('probe', 'ok')")
        }
        try await database.dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'probe'"), "ok")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"),
                Migrations.releasedPrefix.count
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE name = 'schema_meta'"),
                1
            )
        }
    }

    // MARK: - T22 健康状态下重试是空操作（不会重复执行迁移）

    func testT22_RetryIsNoOpWhenHealthy() async throws {
        let paths = DatabasePaths(root: root.appendingPathComponent("t22", isDirectory: true))
        let counter = AttemptCounter()
        let database = try AppDatabase(paths: paths, makeMigrator: {
            counter.value += 1
            return Migrations.migrator
        })

        XCTAssertEqual(counter.value, 1)
        try await database.retryMigration()
        XCTAssertEqual(counter.value, 1, "健康状态下的重试不得再次执行迁移")
        XCTAssertEqual(database.currentSchemaVersion, Migrations.latest.rawValue)
    }

    // MARK: - T23 结构与必要索引门禁

    func testT23_RequiredObjectGateDetectsMissingIndex() throws {
        let database = try AppDatabase(
            paths: DatabasePaths(root: root.appendingPathComponent("t23", isDirectory: true))
        )
        // 升级完成后，门禁必须通过
        try database.dbQueue.read { db in try SchemaMeta.verifyRequiredObjects(db) }

        // 人为删除一个必要索引后，门禁必须拒绝
        try database.dbQueue.write { db in
            try db.execute(sql: "DROP INDEX ux_memories_dedupe")
        }
        XCTAssertThrowsError(try database.dbQueue.read { db in try SchemaMeta.verifyRequiredObjects(db) }) { error in
            guard case SchemaMetaError.missingObjects(let names) = error else {
                XCTFail("应抛出 missingObjects，实际：\(error)")
                return
            }
            XCTAssertEqual(names, ["ux_memories_dedupe"])
        }
    }
}

// MARK: - 测试辅助（不依赖 self，便于放进 @Sendable 闭包）

/// 计数盒：用于验证"只尝试一次 / 重试一次"
final class AttemptCounter: @unchecked Sendable {
    var value = 0
}

/// 注入失败的迁移器：v1 正常执行，v2 必定抛错
func makeFailingMigrator() -> DatabaseMigrator {
    var migrator = Migrations.makeMigrator(upTo: .v1_phase1)
    migrator.registerMigration("v2_memory") { _ in
        throw DFError.database("注入失败：模拟 v2 迁移中断")
    }
    return migrator
}
