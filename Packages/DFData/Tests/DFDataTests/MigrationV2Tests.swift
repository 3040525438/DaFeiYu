import XCTest
import GRDB
import DFCore
@testable import DFData

/// v2_memory 迁移测试（T01–T14）
final class MigrationV2Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFV2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 辅助

    /// 构造只跑到 v1_phase1 的库。
    /// 显式关闭外键，用于模拟历史脏数据（孤儿 persona_items 等），
    /// 避免测试结果依赖 GRDB 的默认值。
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

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
    }

    private func insertMemory(
        _ db: Database,
        id: String,
        title: String,
        content: String,
        importance: String,
        firstSeenAt: Int64 = 1_700_000_000_000
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES (?, 'fact', ?, ?, ?, ?)
            """,
            arguments: [id, title, content, importance, firstSeenAt]
        )
    }

    private func contentFingerprint(_ db: Database) throws -> String {
        let rows = try MemoryContentRow.fetchAll(db, sql: "SELECT id, content FROM memories ORDER BY id")
        let buffer = rows.map { "\($0.id)\u{1F}\($0.content)\u{1E}" }.joined()
        return SHA256.hash(buffer)
    }

    // MARK: - T01 空库全量迁移

    func testT01_FreshDatabaseMigratesToV2() throws {
        let database = try makeDatabase("t01")

        XCTAssertEqual(database.currentSchemaVersion, "v3_chat")
        XCTAssertFalse(database.isReadOnly)

        let ledger = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertEqual(Set(ledger), ["v1_phase1", "v2_memory", "v3_chat"])

        let tableCount = try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='memory_scopes'") ?? 0
        }
        XCTAssertEqual(tableCount, 1)
    }

    // MARK: - T02 v1 库增量迁移

    func testT02_IncrementalFromV1KeepsCounts() throws {
        let queue = try makeV1Queue("t02")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            for index in 1...3 {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: ["m\(index)", UUID().uuidString, "第\(index)条", index]
                )
            }
            try insertMemory(db, id: "mem1", title: "摄影", content: "今天去看了摄影展", importance: "high")
            try insertMemory(db, id: "mem2", title: "猫", content: "她养了一只猫", importance: "normal")
        }

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 2)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT max(identifier) FROM grdb_migrations"), "v3_chat")
        }
    }

    // MARK: - T03 幂等

    func testT03_MigratingTwiceIsIdempotent() throws {
        let queue = try makeV1Queue("t03")
        try Migrations.migrator.migrate(queue)
        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations"), 3)
        }
    }

    // MARK: - T04 列结构与旧列不变

    func testT04_MemoriesColumns() throws {
        let database = try makeDatabase("t04")
        let columns = try database.dbQueue.read { db in
            try ColumnInfoRow.fetchAll(db, sql: "PRAGMA table_info(memories)")
        }

        // (列名, 类型, NOT NULL, 默认值) —— 前 13 项是 v1 旧列，必须原样不动
        let expected: [(String, String, Bool, String?)] = [
            ("id", "TEXT", false, nil),   // TEXT PRIMARY KEY：SQLite 允许 NULL，历史行为不变
            ("type", "TEXT", true, nil),
            ("title", "TEXT", true, nil),
            ("content", "TEXT", true, nil),
            ("importance", "TEXT", true, "'normal'"),
            ("salience", "REAL", true, "0.5"),
            ("confidence", "REAL", true, "0.5"),
            ("valid_from", "INTEGER", false, nil),
            ("valid_to", "INTEGER", false, nil),
            ("status", "TEXT", true, "'active'"),
            ("first_seen_at", "INTEGER", true, nil),
            ("last_recalled_at", "INTEGER", false, nil),
            ("recall_count", "INTEGER", true, "0"),
            ("scope", "TEXT", true, "'shared'"),
            ("layer", "TEXT", true, "'semantic'"),
            ("category", "TEXT", true, "'fact'"),
            ("source_kind", "TEXT", true, "'real_interaction'"),
            ("epistemic_status", "TEXT", true, "'observed'"),
            ("version", "INTEGER", true, "1"),
            ("subject_entity_id", "TEXT", false, nil),
            ("dedupe_key", "TEXT", false, nil),
            ("heat", "TEXT", true, "'warm'"),
            ("archived_at", "INTEGER", false, nil),
            ("deleted_at", "INTEGER", false, nil),
            ("created_at", "INTEGER", true, "0"),
            ("updated_at", "INTEGER", true, "0"),
            ("importance_score", "REAL", false, nil),
            ("importance_source", "TEXT", true, "'unparsed'"),
            ("importance_source_at", "INTEGER", false, nil),
            ("classification_status", "TEXT", true, "'pending'"),
            ("original_external_id", "TEXT", false, nil),
            ("original_content", "TEXT", false, nil),
            ("original_created_at", "INTEGER", false, nil),
            ("import_batch_id", "TEXT", false, nil),
            ("classification_evidence_json", "TEXT", true, "'[]'"),
            ("classified_by", "TEXT", false, nil),
            ("classified_at", "INTEGER", false, nil)
        ]

        XCTAssertEqual(columns.count, 37, "memories 应为 13 旧列 + 24 新列")
        guard columns.count == expected.count else { return }

        for (index, item) in expected.enumerated() {
            let column = columns[index]
            let label = "第 \(index) 列 \(item.0)"
            XCTAssertEqual(column.name, item.0, "\(label) 名称/顺序不符")
            XCTAssertEqual(column.type.uppercased(), item.1, "\(label) 类型不符")
            XCTAssertEqual(column.notnull == 1, item.2, "\(label) NOT NULL 不符")
            XCTAssertEqual(column.dfltValue?.trimmingCharacters(in: .whitespaces), item.3, "\(label) 默认值不符")
        }

        // 旧 importance 仍是 TEXT NOT NULL DEFAULT 'normal'，语义未被改写
        let importance = columns[4]
        XCTAssertEqual(importance.name, "importance")
        XCTAssertEqual(importance.type.uppercased(), "TEXT")
        XCTAssertEqual(importance.notnull, 1)
        XCTAssertEqual(importance.dfltValue?.trimmingCharacters(in: .whitespaces), "'normal'")
        // 新列 imporance_score 必须可空且无默认值
        XCTAssertNil(columns[26].dfltValue)
        // 只有 id 是主键
        XCTAssertEqual(columns.filter { $0.pk == 1 }.map(\.name), ["id"])
    }

    // MARK: - T05 content 指纹不变

    func testT05_ContentFingerprintUnchanged() throws {
        let queue = try makeV1Queue("t05")
        try queue.write { db in
            try insertMemory(db, id: "a", title: "计划", content: "周末去看展", importance: "high")
            try insertMemory(db, id: "b", title: "工作", content: "下周要交方案", importance: "normal")
        }
        let before = try queue.read { try contentFingerprint($0) }

        try Migrations.migrator.migrate(queue)

        let after = try queue.read { try contentFingerprint($0) }
        XCTAssertEqual(before, after)
    }

    // MARK: - T06 importance 映射

    func testT06_ImportanceMapping() throws {
        let queue = try makeV1Queue("t06")
        try queue.write { db in
            try insertMemory(db, id: "s1", title: "高", content: "高", importance: "high")
            try insertMemory(db, id: "s2", title: "中", content: "中", importance: "normal")
            try insertMemory(db, id: "s3", title: "低", content: "低", importance: "low")
            try insertMemory(db, id: "s4", title: "数字", content: "数字", importance: "0.42")
            try insertMemory(db, id: "s5", title: "百分", content: "百分", importance: "80")
            try insertMemory(db, id: "s6", title: "中文", content: "中文", importance: "重要 ")
        }

        try Migrations.migrator.migrate(queue)

        let result = try queue.read { db in
            try ImportanceRow.fetchAll(db, sql: "SELECT id, importance, importance_score, importance_source FROM memories ORDER BY id")
        }
        let byId = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })

        XCTAssertEqual(byId["s1"]?.importanceScore, 0.80)
        XCTAssertEqual(byId["s1"]?.importanceSource, "legacy_text")
        XCTAssertEqual(byId["s2"]?.importanceScore, 0.50)
        XCTAssertEqual(byId["s3"]?.importanceScore, 0.30)
        XCTAssertEqual(byId["s4"]?.importanceScore, 0.42)
        XCTAssertEqual(byId["s4"]?.importanceSource, "legacy_numeric")
        XCTAssertNil(byId["s5"]?.importanceScore)
        XCTAssertEqual(byId["s5"]?.importanceSource, "unparsed")
        XCTAssertEqual(byId["s6"]?.importanceScore, 0.80)
        // 原始 TEXT 不被改写
        XCTAssertEqual(byId["s6"]?.importance, "重要 ")
    }

    // MARK: - T07 NULL 不写回

    func testT07_UnparsedStaysNull() throws {
        let queue = try makeV1Queue("t07")
        try queue.write { db in
            try insertMemory(db, id: "u1", title: "甲", content: "甲", importance: "80")
            try insertMemory(db, id: "u2", title: "乙", content: "乙", importance: "很重要")
            try insertMemory(db, id: "u3", title: "丙", content: "丙", importance: "high")
        }

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let nulls = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories WHERE importance_score IS NULL")
            let unparsed = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories WHERE importance_source = 'unparsed'")
            XCTAssertEqual(nulls, unparsed)
            XCTAssertEqual(unparsed, 2)

            let wronglyScored = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM memories WHERE importance_source = 'unparsed' AND importance_score IS NOT NULL"
            )
            XCTAssertEqual(wronglyScored, 0)

            // 解析失败必须留痕
            let history = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM memory_importance_history WHERE reason = 'parse_failed'"
            )
            XCTAssertEqual(history, 2)
        }
    }

    // MARK: - T08 FTS

    func testT08_FullTextSearch() throws {
        let queue = try makeV1Queue("t08")
        try queue.write { db in
            try insertMemory(db, id: "f1", title: "摄影", content: "今天去看了摄影展", importance: "high")
            try insertMemory(db, id: "f2", title: "天气", content: "明天可能下雨", importance: "normal")
        }

        try Migrations.migrator.migrate(queue)

        try queue.read { db in
            let ftsCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_fts")
            let memoryCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories")
            XCTAssertEqual(ftsCount, memoryCount)

            let hits = try String.fetchAll(db, sql: "SELECT memory_id FROM memory_fts WHERE memory_fts MATCH '摄影'")
            XCTAssertEqual(hits, ["f1"])
        }
    }

    // MARK: - T09 视图

    func testT09_ViewsQueryable() throws {
        let database = try makeDatabase("t09")
        try database.dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope)
            VALUES ('v1', 'fact', '用户', '喜欢猫', 'normal', 1, 'user')
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope)
            VALUES ('v2', 'event', '共同', '一起看展', 'normal', 1, 'shared')
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at, scope)
            VALUES ('v3', 'reflection', '自身', '我最近在想摄影', 'normal', 1, 'self')
            """)
        }

        try database.dbQueue.read { db in
            let user = try Int.fetchOne(db, sql: "SELECT count(*) FROM v_memory_user")
            let shared = try Int.fetchOne(db, sql: "SELECT count(*) FROM v_memory_shared")
            let selfScope = try Int.fetchOne(db, sql: "SELECT count(*) FROM v_memory_self")
            let stats = try Int.fetchOne(db, sql: "SELECT count(*) FROM v_memory_stats")
            XCTAssertEqual(user, 1)
            XCTAssertEqual(shared, 1)
            XCTAssertEqual(selfScope, 1)
            XCTAssertEqual(stats, 3)
        }
    }

    // MARK: - T10 digest 跨库复现

    func testT10_DigestReproducibleAcrossDatabases() throws {
        let first = try makeDatabase("t10-a")
        let second = try makeDatabase("t10-b")

        func digest(_ database: AppDatabase) throws -> String {
            try database.dbQueue.read { db in
                try SchemaMeta.value(db, key: SchemaMetaKey.ledgerDigest) ?? ""
            }
        }

        let a = try digest(first)
        let b = try digest(second)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, MigrationLedger.digest(prefix: ["v1_phase1", "v2_memory", "v3_chat"]))
    }

    // MARK: - T11 顺序防护

    func testT11_OutOfOrderRegistrationIsRejected() throws {
        let queue = try makeV1Queue("t11")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v3_chat')")
        }

        XCTAssertThrowsError(try Migrations.migrator.migrate(queue))

        try queue.read { db in
            let hasMeta = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'"
            )
            XCTAssertEqual(hasMeta, 0, "失败必须整体回滚，不留下半成品结构")
            let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertEqual(Set(identifiers), ["v1_phase1", "v3_chat"])
        }
    }

    // MARK: - T12 失败回滚

    func testT12_FailureRollsBackEverything() throws {
        let queue = try makeV1Queue("t12")

        XCTAssertThrowsError(
            try queue.write { db in
                try V2Memory.migrate(db)
                throw DFError.database("注入失败：强制回滚")
            }
        )

        try queue.read { db in
            let hasMeta = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'"
            )
            let hasScopes = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='memory_scopes'"
            )
            XCTAssertEqual(hasMeta, 0)
            XCTAssertEqual(hasScopes, 0)
        }
    }

    // MARK: - T13 性能

    func testT13_MigrationPerformance() throws {
        let queue = try makeV1Queue("t13")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)

            let messageStatement = try db.makeStatement(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?)
            """)
            for index in 1...17_000 {
                try messageStatement.execute(arguments: ["m\(index)", UUID().uuidString, "消息 \(index)", index])
            }

            let memoryStatement = try db.makeStatement(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES (?, 'fact', ?, ?, ?, ?)
            """)
            for index in 1...5_000 {
                try memoryStatement.execute(arguments: [
                    "mem\(index)", "标题\(index)", "内容\(index) 今天聊到了摄影", index % 2 == 0 ? "high" : "normal", index
                ])
            }
        }

        let startedAt = Date()
        try Migrations.migrator.migrate(queue)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThanOrEqual(elapsed, 8.0, "迁移耗时 \(elapsed)s 超过 8 秒")

        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages"), 17_000)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memories"), 5_000)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_fts"), 5_000)
            XCTAssertEqual((try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "").lowercased(), "ok")
        }
    }

    // MARK: - T14 只读降级

    func testT14_MetaTamperSwitchesToReadOnly() throws {
        let path = root.appendingPathComponent("t14", isDirectory: true)
        let paths = DatabasePaths(root: path)

        let first = try AppDatabase(paths: paths)
        XCTAssertFalse(first.isReadOnly)
        try first.dbQueue.write { db in
            try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: "v9_broken", at: 1)
        }

        let second = try AppDatabase(paths: paths)
        XCTAssertTrue(second.isReadOnly)
        XCTAssertThrowsError(try second.assertWritable())
    }

    // MARK: - T15 人格层级三值映射（D-B 补充）

    func testT15_PersonaTierBackfill() throws {
        // 纯函数口径
        XCTAssertEqual(V2Memory.tierMapping(hasPersona: true, kind: "core", isLocked: 1).tier, "core")
        XCTAssertEqual(V2Memory.tierMapping(hasPersona: true, kind: "outer", isLocked: 1).tier, "outer")
        XCTAssertEqual(V2Memory.tierMapping(hasPersona: true, kind: "outer", isLocked: 1).conflict, "locked_outer")
        XCTAssertEqual(V2Memory.tierMapping(hasPersona: true, kind: "weird", isLocked: 0).tier, "pending")
        XCTAssertEqual(V2Memory.tierMapping(hasPersona: false, kind: nil, isLocked: nil).source, "orphan")

        let queue = try makeV1Queue("t15")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, created_at, updated_at)
            VALUES ('p-core', 'core', '核心人格', 1, 1, 1), ('p-outer', 'outer', '外围人格', 1, 1, 1), ('p-bad', 'weird', '异常', 0, 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO persona_items (id, persona_id, section, key, value, updated_at) VALUES
             ('i1', 'p-core', 'core', 'style', '温柔', 1),
             ('i2', 'p-outer', 'outer', 'hobby', '摄影', 1),
             ('i3', 'p-bad', 'x', 'k', 'v', 1),
             ('i4', 'p-missing', 'x', 'k', 'v', 1)
            """)
        }

        try Migrations.migrator.migrate(queue)

        let rows = try queue.read { db in
            try PersonaTierRow.fetchAll(
                db,
                sql: "SELECT id, tier, tier_status, tier_source, tier_conflict FROM persona_items ORDER BY id"
            )
        }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertEqual(byId["i1"]?.tier, "core")
        XCTAssertEqual(byId["i2"]?.tier, "outer", "locked+outer 必须保留 outer")
        XCTAssertEqual(byId["i2"]?.tierConflict, "locked_outer")
        XCTAssertEqual(byId["i3"]?.tier, "pending")
        XCTAssertEqual(byId["i3"]?.tierSource, "invalid_kind")
        XCTAssertEqual(byId["i4"]?.tier, "pending")
        XCTAssertEqual(byId["i4"]?.tierSource, "orphan")
        // 原始 value 不得被改写
        let value = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM persona_items WHERE id = 'i2'")
        }
        XCTAssertEqual(value, "摄影")
    }

    // MARK: - T16 只读降级集中拦截

    func testT16_ReadOnlyBlocksRepositoryAndFacadeWrites() async throws {
        let paths = DatabasePaths(root: root.appendingPathComponent("t16", isDirectory: true))

        // 1) 正常状态：仓储写入必须成功
        let healthy = try AppDatabase(paths: paths)
        XCTAssertFalse(healthy.isReadOnly)
        let writer = GRDBSettingsRepository(database: healthy)
        try await writer.set("dark", for: "theme")
        let stored = try await healthy.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'theme'")
        }
        XCTAssertEqual(stored, "dark")

        // 2) 篡改 meta 后重开 → 只读
        try await healthy.dbQueue.write { db in
            try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: "v9_broken", at: 1)
        }
        let readOnly = try AppDatabase(paths: paths)
        XCTAssertTrue(readOnly.isReadOnly)

        // 3) 现有仓储写入入口必须被拦截
        let blocked = GRDBSettingsRepository(database: readOnly)
        do {
            try await blocked.set("light", for: "theme")
            XCTFail("只读模式下仓储写入必须抛错")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        // 4) 统一写入入口同样被拦截
        do {
            try await readOnly.write { db in
                try db.execute(sql: "INSERT INTO settings(key, value) VALUES('probe', 'x')")
            }
            XCTFail("只读模式下 write 必须抛错")
        } catch {
            // 预期
        }

        // 5) 库内容未被任何被拒绝的写入改动
        let valueAfter = try await readOnly.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'theme'")
        }
        XCTAssertEqual(valueAfter, "dark")
        let probe = try await readOnly.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'probe'")
        }
        XCTAssertNil(probe)
    }
}

// MARK: - 测试内部查询模型

private struct ColumnInfoRow: Decodable, FetchableRecord {
    var name: String
    var type: String
    var notnull: Int
    var dfltValue: String?
    var pk: Int

    enum CodingKeys: String, CodingKey {
        case name, type, notnull, pk
        case dfltValue = "dflt_value"
    }
}

private struct ImportanceRow: Decodable, FetchableRecord {
    var id: String
    var importance: String
    var importanceScore: Double?
    var importanceSource: String

    enum CodingKeys: String, CodingKey {
        case id, importance
        case importanceScore = "importance_score"
        case importanceSource = "importance_source"
    }
}

private struct MemoryContentRow: Decodable, FetchableRecord {
    var id: String
    var content: String
}

private struct PersonaTierRow: Decodable, FetchableRecord {
    var id: String
    var tier: String?
    var tierStatus: String?
    var tierSource: String?
    var tierConflict: String?

    enum CodingKeys: String, CodingKey {
        case id, tier
        case tierStatus = "tier_status"
        case tierSource = "tier_source"
        case tierConflict = "tier_conflict"
    }
}
