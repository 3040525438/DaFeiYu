import XCTest
import GRDB
import DFCore
@testable import DFData

/// AstrBot 全量导入器测试（W9-5 / W9-6）
final class AstrBotImporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFAstrBot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 夹具

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
    }

    /// 构造一份最小的 AstrBot 源数据：10 条聊天、工具记录、媒体归档、记忆、人格、日记、文档、关系账本
    private func makeSources() throws -> AstrBotSourcePaths {
        let sourceRoot = root.appendingPathComponent("astrbot", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        // 聊天库
        let chatURL = sourceRoot.appendingPathComponent("chat_memory.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let chat = try DatabaseQueue(path: chatURL.path, configuration: configuration)
        try chat.write { db in
            try db.execute(sql: """
            CREATE TABLE chat_memory_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                umo TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                user_id TEXT NOT NULL DEFAULT '',
                role TEXT NOT NULL,
                content TEXT NOT NULL DEFAULT '',
                message_id TEXT,
                pair_id TEXT,
                llm_status TEXT NOT NULL DEFAULT '',
                content_kind TEXT NOT NULL DEFAULT '[]',
                platform_id TEXT,
                platform_name TEXT,
                message_type TEXT,
                session_id TEXT,
                self_id TEXT,
                group_id TEXT,
                sender_nickname TEXT,
                raw_timestamp INTEGER,
                at_id TEXT,
                reply_id TEXT,
                forward_id TEXT,
                persona_id TEXT,
                created_at DATETIME NOT NULL,
                turn_id TEXT,
                send_status TEXT NOT NULL DEFAULT '',
                relation_data TEXT,
                recalled_at DATETIME,
                deleted_at DATETIME
            )
            """)
            try db.execute(sql: """
            CREATE TABLE chat_memory_tool_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                umo TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                call_index INTEGER NOT NULL,
                tool_name TEXT NOT NULL,
                tool_args TEXT NOT NULL DEFAULT '',
                tool_result TEXT NOT NULL DEFAULT '',
                created_at DATETIME NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE chat_memory_media_archive (
                media_id TEXT PRIMARY KEY,
                umo TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                file_name TEXT NOT NULL,
                ext TEXT NOT NULL,
                mime_type TEXT,
                size_bytes INTEGER NOT NULL,
                created_at DATETIME NOT NULL
            )
            """)

            func insertRecord(
                id: Int64,
                role: String,
                content: String,
                kind: String,
                raw: Int64?,
                createdAt: String,
                messageID: String? = nil,
                replyID: String? = nil,
                recalledAt: String? = nil
            ) throws {
                try db.execute(
                    sql: """
                    INSERT INTO chat_memory_records
                        (id, umo, conversation_id, user_id, role, content, message_id, reply_id,
                         content_kind, platform_id, platform_name, raw_timestamp, created_at, recalled_at)
                    VALUES (?, 'umo-1', 'conv-1', 'u1', ?, ?, ?, ?, ?, 'qq', 'QQ', ?, ?, ?)
                    """,
                    arguments: [id, role, content, messageID, replyID, kind, raw, createdAt, recalledAt]
                )
            }

            try insertRecord(id: 1, role: "user", content: "晚安", kind: "[\"text\"]",
                             raw: 1792806457, createdAt: "2026-10-24 01:47:37")
            try insertRecord(id: 2, role: "assistant", content: "晚安呀，快睡", kind: "[\"text\"]",
                             raw: nil, createdAt: "2026-10-24 01:47:40.123456")
            try insertRecord(id: 3, role: "user", content: "[image]", kind: "[\"image\"]",
                             raw: 1792806460, createdAt: "2026-10-24 01:47:40")
            try insertRecord(id: 4, role: "user", content: "[系统通知]", kind: "[\"event\"]",
                             raw: 1792806461, createdAt: "2026-10-24 01:47:41")
            try insertRecord(id: 5, role: "system", content: "系统消息", kind: "[\"text\"]",
                             raw: 1792806462, createdAt: "2026-10-24 01:47:42")
            try insertRecord(id: 6, role: "user", content: "已经撤回的话", kind: "[\"text\"]",
                             raw: 1792806463, createdAt: "2026-10-24 01:47:43",
                             recalledAt: "2026-10-24 02:00:00")
            try insertRecord(id: 7, role: "user", content: "回复目标", kind: "[\"text\"]",
                             raw: 1792806464, createdAt: "2026-10-24 01:47:44",
                             messageID: "pm-1")
            try insertRecord(id: 8, role: "assistant", content: "回复内容", kind: "[\"text\"]",
                             raw: 1792806465, createdAt: "2026-10-24 01:47:45",
                             replyID: "pm-1")
            try insertRecord(id: 9, role: "user", content: "", kind: "[\"text\"]",
                             raw: 1792806466, createdAt: "2026-10-24 01:47:46")
            try insertRecord(id: 10, role: "user", content: "时间坏掉的消息", kind: "[\"text\"]",
                             raw: nil, createdAt: "不是时间")

            try db.execute(sql: """
            INSERT INTO chat_memory_tool_records
                (id, umo, conversation_id, turn_id, call_index, tool_name, tool_args, tool_result, created_at)
            VALUES (1, 'umo-1', 'conv-1', 'turn-1', 0, 'web_search', '{}', '{}', '2026-10-24 01:47:47')
            """)
            try db.execute(sql: """
            INSERT INTO chat_memory_media_archive
                (media_id, umo, conversation_id, turn_id, kind, file_name, ext, mime_type, size_bytes, created_at)
            VALUES ('media-1', 'umo-1', 'conv-1', 'turn-1', 'image', 'a.jpg', 'jpg', 'image/jpeg', 1024, '2026-10-24 01:47:48')
            """)
        }
        try chat.close()

        // 长期记忆库
        let memoryURL = sourceRoot.appendingPathComponent("memory.db")
        let memory = try DatabaseQueue(path: memoryURL.path, configuration: configuration)
        try memory.write { db in
            try db.execute(sql: "CREATE TABLE mem(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, day TEXT, text TEXT, sig TEXT UNIQUE)")
            try db.execute(
                sql: "INSERT INTO mem (id, kind, day, text, sig) VALUES (1, 'fact', '2026-10-24', '2026-10-24｜画签名', 'sig-1')"
            )
            try db.execute(
                sql: "INSERT INTO mem (id, kind, day, text, sig) VALUES (2, 'chat', '2026-10-26', '2026-10-26｜聊到很晚', 'sig-2')"
            )
            try db.execute(
                sql: "INSERT INTO mem (id, kind, day, text, sig) VALUES (3, 'fact', '不是日期', '日期坏了', 'sig-3')"
            )
            try db.execute(
                sql: "INSERT INTO mem (id, kind, day, text, sig) VALUES (4, 'diary', '2026-10-27', '', 'sig-4')"
            )
        }
        try memory.close()

        // 人格库
        let personaURL = sourceRoot.appendingPathComponent("data_v4.db")
        let persona = try DatabaseQueue(path: personaURL.path, configuration: configuration)
        try persona.write { db in
            try db.execute(sql: """
            CREATE TABLE personas (
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL,
                id INTEGER NOT NULL PRIMARY KEY,
                persona_id VARCHAR(255) NOT NULL UNIQUE,
                system_prompt TEXT NOT NULL,
                begin_dialogs JSON,
                tools JSON,
                skills JSON
            )
            """)
            try db.execute(
                sql: """
                INSERT INTO personas (created_at, updated_at, id, persona_id, system_prompt)
                VALUES ('2026-10-01', '2026-10-01', 1, 'whale', '你是鲸鱼娘，名字叫小肥。')
                """
            )
        }
        try persona.close()

        // 日记：2 篇有效、1 篇非日记文件、1 个 txt 镜像
        let diaryURL = sourceRoot.appendingPathComponent("diary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: diaryURL.appendingPathComponent("txt", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# 2026年10月24日 · 周六\n\n今天画了签名。"
            .write(to: diaryURL.appendingPathComponent("2026-10-24.md"), atomically: true, encoding: .utf8)
        try "# 2026年10月25日 · 周日\n\n今天聊到很晚。"
            .write(to: diaryURL.appendingPathComponent("2026-10-25.md"), atomically: true, encoding: .utf8)
        try "# 长期事实\n\n- 喜欢白米饭"
            .write(to: diaryURL.appendingPathComponent("FACTS.md"), atomically: true, encoding: .utf8)
        try "2026-10-24\n今天画了签名。"
            .write(to: diaryURL.appendingPathComponent("txt/2026-10-24.txt"), atomically: true, encoding: .utf8)

        // 信件与读书笔记
        let lettersURL = sourceRoot.appendingPathComponent("letters", isDirectory: true)
        try FileManager.default.createDirectory(at: lettersURL, withIntermediateDirectories: true)
        try "# 第一天\n\n写给你的第一封信。"
            .write(to: lettersURL.appendingPathComponent("2026-10-25.md"), atomically: true, encoding: .utf8)

        let booksURL = sourceRoot.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: booksURL, withIntermediateDirectories: true)
        try "# 读书笔记\n\n记住一句话。"
            .write(to: booksURL.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        // 关系账本
        let ledgerURL = sourceRoot.appendingPathComponent("companions.json")
        let ledger = """
        {"version":1,"users":{"3040525438":{"relationship_role":"friend","relationship_mode":"normal","relationship_ledger":[]},
        "111":{"relationship_role":"stranger","relationship_mode":"normal","relationship_ledger":[]}}}
        """
        try ledger.write(to: ledgerURL, atomically: true, encoding: .utf8)

        return AstrBotSourcePaths(
            chatMemoryDatabase: chatURL,
            longTermMemoryDatabase: memoryURL,
            personaDatabase: personaURL,
            diaryDirectory: diaryURL,
            lettersDirectory: lettersURL,
            bookNotesDirectory: booksURL,
            companionLedgerJSON: ledgerURL
        )
    }

    private func count(_ database: AppDatabase, _ sql: String) async throws -> Int {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func string(
        _ database: AppDatabase,
        _ sql: String,
        _ arguments: StatementArguments = StatementArguments()
    ) async throws -> String? {
        try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: sql, arguments: arguments)
        }
    }

    // MARK: - 全量导入

    func testImportsAllSourcesWithCoverage() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let source = try makeSources()
        let chatHashBefore = try AstrBotImporter.fileHash(source.chatMemoryDatabase!)

        let report = try await importer.run(
            source: source,
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(report.status, .succeeded)
        XCTAssertFalse(report.isDryRun)

        // 源行覆盖：10 = 6 新增 + 0 重复 + 4 待处理
        XCTAssertEqual(report.counts.sourceChatRecords, 10)
        XCTAssertEqual(report.counts.messagesNew, 6)
        XCTAssertEqual(report.counts.messagesDuplicate, 0)
        XCTAssertEqual(report.counts.messagesPending, 4)
        XCTAssertEqual(report.counts.sourceMemories, 4)
        XCTAssertEqual(report.counts.memoriesNew, 2)
        XCTAssertEqual(report.counts.memoriesPending, 2)
        XCTAssertEqual(report.counts.sourceDiaryFiles, 4)
        XCTAssertEqual(report.counts.diariesNew, 2)
        XCTAssertEqual(report.counts.diaryMirrors, 1)
        XCTAssertEqual(report.counts.diaryPending, 1)
        XCTAssertEqual(report.counts.personaRowsImported, 1)
        XCTAssertEqual(report.counts.sourceDocuments, 2)
        XCTAssertEqual(report.counts.documentsNew, 2)
        XCTAssertEqual(report.counts.sourceLedgerUsers, 2)
        XCTAssertEqual(report.counts.ledgerPending, 2)
        XCTAssertEqual(report.counts.pendingToolRecords, 1)
        XCTAssertEqual(report.counts.pendingMediaArchives, 1)
        XCTAssertEqual(report.counts.pendingMediaMissing, 1)
        XCTAssertEqual(report.counts.pendingReplyTargetMissing, 0)
        XCTAssertEqual(report.counts.pendingTotal, 12)
        XCTAssertTrue(report.counts.coverageProblems.isEmpty)

        // 会话
        let conversations = try await count(database, "SELECT count(*) FROM conversations")
        XCTAssertEqual(conversations, 1)

        // 消息：角色 / 状态 / 回复映射
        let messages = try await count(database, "SELECT count(*) FROM messages")
        XCTAssertEqual(messages, 6)
        let recalled = try await string(
            database,
            "SELECT status FROM messages WHERE id = ?",
            ["astrbot-msg-6"]
        )
        XCTAssertEqual(recalled, "recalled")
        let reply = try await string(
            database,
            "SELECT reply_to_id FROM messages WHERE id = ?",
            ["astrbot-msg-8"]
        )
        XCTAssertEqual(reply, "astrbot-msg-7")
        let importedOrigin = try await count(
            database,
            "SELECT count(*) FROM messages WHERE origin = 'imported'"
        )
        XCTAssertEqual(importedOrigin, 6)

        // 记忆：2 条 AstrBot 记忆 + 2 条文档（信件/读书笔记），全部 shared
        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 4)
        let scope = try await string(database, "SELECT scope FROM memories WHERE type = 'fact'")
        XCTAssertEqual(scope, "shared")
        let classification = try await string(
            database,
            "SELECT classification_status FROM memories WHERE type = 'fact'"
        )
        XCTAssertEqual(classification, "pending")
        let originalID = try await string(
            database,
            "SELECT original_external_id FROM memories WHERE type = 'fact'"
        )
        XCTAssertEqual(originalID, "sig-1")

        // 日记与版本
        let diaries = try await count(database, "SELECT count(*) FROM diary_entries")
        XCTAssertEqual(diaries, 2)
        let versions = try await count(database, "SELECT count(*) FROM diary_entry_versions")
        XCTAssertEqual(versions, 2)

        // 人格：核心人格 + 版本 + 指纹
        let personas = try await count(database, "SELECT count(*) FROM personas WHERE kind = 'core'")
        XCTAssertEqual(personas, 1)
        let prompt = try await string(
            database,
            "SELECT value FROM persona_items WHERE key = 'system_prompt'"
        )
        XCTAssertEqual(prompt, "你是鲸鱼娘，名字叫小肥。")
        let personaVersions = try await count(database, "SELECT count(*) FROM persona_versions")
        XCTAssertEqual(personaVersions, 1)

        // 全文索引
        let messageFTS = try await count(database, "SELECT count(*) FROM message_fts")
        XCTAssertEqual(messageFTS, 6)
        let memoryFTS = try await count(database, "SELECT count(*) FROM memory_fts")
        XCTAssertEqual(memoryFTS, 4)
        let diaryFTS = try await count(database, "SELECT count(*) FROM diary_fts")
        XCTAssertEqual(diaryFTS, 2)

        // 原始数据保护：源文件 SHA256 前后一致
        let chatHashAfter = try AstrBotImporter.fileHash(source.chatMemoryDatabase!)
        XCTAssertEqual(chatHashAfter, chatHashBefore)
        XCTAssertFalse(report.sourceHash.isEmpty)
    }

    // MARK: - 待处理区

    func testUnknownRowsLandInPendingWithRawJSON() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let report = try await importer.run(
            source: try makeSources(),
            options: AstrBotImportOptions(isDryRun: false)
        )

        let items = try await importer.pendingItems(batchID: report.batchID, limit: 100)
        XCTAssertEqual(items.count, report.counts.pendingTotal)

        let event = items.first { $0.reasonCode == AstrBotPendingReason.systemEvent.rawValue }
        XCTAssertNotNil(event)
        XCTAssertTrue(event?.rawJSON.contains("系统通知") == true)

        let invalidDay = items.first { $0.reasonCode == AstrBotPendingReason.invalidDay.rawValue }
        XCTAssertNotNil(invalidDay)
        XCTAssertTrue(invalidDay?.rawJSON.contains("日期坏了") == true)

        let ledger = items.filter { $0.reasonCode == AstrBotPendingReason.relationshipLedger.rawValue }
        XCTAssertEqual(ledger.count, 2)

        let resolvedCount = try await count(
            database,
            "SELECT count(*) FROM astrbot_import_pending WHERE status <> 'pending'"
        )
        XCTAssertEqual(resolvedCount, 0)
    }

    // MARK: - 预演

    func testDryRunWritesNoBusinessData() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let report = try await importer.run(
            source: try makeSources(),
            options: AstrBotImportOptions(isDryRun: true)
        )

        XCTAssertEqual(report.status, .dryRunSucceeded)
        XCTAssertEqual(report.counts.messagesNew, 6)

        let messages = try await count(database, "SELECT count(*) FROM messages")
        XCTAssertEqual(messages, 0)
        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 0)
        let diaries = try await count(database, "SELECT count(*) FROM diary_entries")
        XCTAssertEqual(diaries, 0)
        let personas = try await count(database, "SELECT count(*) FROM personas")
        XCTAssertEqual(personas, 0)
        let pending = try await count(database, "SELECT count(*) FROM astrbot_import_pending")
        XCTAssertEqual(pending, 0)
        let idMaps = try await count(database, "SELECT count(*) FROM astrbot_id_map")
        XCTAssertEqual(idMaps, 0)

        let batches = try await importer.batches(limit: 10)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.status, "dry_run_succeeded")
        XCTAssertEqual(batches.first?.counts.messagesNew, 6)
    }

    // MARK: - 幂等

    func testSecondImportIsIdempotent() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let source = try makeSources()

        let first = try await importer.run(source: source, options: AstrBotImportOptions(isDryRun: false))
        XCTAssertEqual(first.counts.messagesNew, 6)

        let second = try await importer.run(source: source, options: AstrBotImportOptions(isDryRun: false))
        XCTAssertEqual(second.status, .succeeded)
        XCTAssertEqual(second.counts.messagesNew, 0)
        XCTAssertEqual(second.counts.messagesDuplicate, 6)
        XCTAssertEqual(second.counts.memoriesNew, 0)
        XCTAssertEqual(second.counts.memoriesDuplicate, 2)
        XCTAssertEqual(second.counts.diariesNew, 0)
        XCTAssertEqual(second.counts.diaryDuplicates, 2)
        XCTAssertEqual(second.counts.documentsNew, 0)
        XCTAssertEqual(second.counts.documentsDuplicate, 2)
        XCTAssertTrue(second.counts.coverageProblems.isEmpty)

        let messages = try await count(database, "SELECT count(*) FROM messages")
        XCTAssertEqual(messages, 6)
        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 4)
        let diaries = try await count(database, "SELECT count(*) FROM diary_entries")
        XCTAssertEqual(diaries, 2)
        let personas = try await count(database, "SELECT count(*) FROM personas")
        XCTAssertEqual(personas, 1)
    }

    // MARK: - 回滚

    func testRollbackRemovesOnlyImportedEntities() async throws {
        let database = try makeDatabase("app")
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c-legacy', '旧会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m-legacy', 'legacy-1', 'c-legacy', 'user', 'text', '旧消息', 'sent', 'user', 2)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, first_seen_at)
            VALUES ('mem-legacy', 'fact', '旧记忆', '旧内容', 'normal', 1)
            """)
        }

        let importer = AstrBotImporter(database: database)
        let report = try await importer.run(
            source: try makeSources(),
            options: AstrBotImportOptions(isDryRun: false)
        )
        let importedMessageCount = try await count(database, "SELECT count(*) FROM messages")
        XCTAssertEqual(importedMessageCount, 7)

        let rollback = try await importer.rollback(batchID: report.batchID, at: Clock.nowMillis())
        XCTAssertEqual(rollback.status, .rolledBack)
        XCTAssertEqual(rollback.deletedMessages, 6)
        XCTAssertEqual(rollback.deletedConversations, 1)
        XCTAssertEqual(rollback.deletedMemories, 4)
        XCTAssertEqual(rollback.deletedDiaries, 2)
        XCTAssertEqual(rollback.deletedPersonas, 1)

        // 既有数据完好
        let legacyMessages = try await count(database, "SELECT count(*) FROM messages WHERE id = 'm-legacy'")
        let legacyMemories = try await count(database, "SELECT count(*) FROM memories WHERE id = 'mem-legacy'")
        let legacyConversations = try await count(database, "SELECT count(*) FROM conversations WHERE id = 'c-legacy'")
        XCTAssertEqual(legacyMessages, 1)
        XCTAssertEqual(legacyMemories, 1)
        XCTAssertEqual(legacyConversations, 1)

        // 导入数据全部清空
        let importedMessages = try await count(
            database,
            "SELECT count(*) FROM messages WHERE client_uuid LIKE 'astrbot:%'"
        )
        let importedMemories = try await count(
            database,
            "SELECT count(*) FROM memories WHERE dedupe_key LIKE 'astrbot:%'"
        )
        let diaryCount = try await count(database, "SELECT count(*) FROM diary_entries")
        let personaCount = try await count(database, "SELECT count(*) FROM personas")
        let personaItemCount = try await count(database, "SELECT count(*) FROM persona_items")
        let pendingCount = try await count(database, "SELECT count(*) FROM astrbot_import_pending")
        let idMapCount = try await count(database, "SELECT count(*) FROM astrbot_id_map")
        let messageFTS = try await count(database, "SELECT count(*) FROM message_fts")
        let memoryFTS = try await count(database, "SELECT count(*) FROM memory_fts")
        let diaryFTS = try await count(database, "SELECT count(*) FROM diary_fts")
        let personaImports = try await count(database, "SELECT count(*) FROM persona_imports")
        XCTAssertEqual(importedMessages, 0)
        XCTAssertEqual(importedMemories, 0)
        XCTAssertEqual(diaryCount, 0)
        XCTAssertEqual(personaCount, 0)
        XCTAssertEqual(personaItemCount, 0)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(idMapCount, 0)
        XCTAssertEqual(messageFTS, 0)
        XCTAssertEqual(memoryFTS, 0)
        XCTAssertEqual(diaryFTS, 0)
        XCTAssertEqual(personaImports, 0)

        let status = try await string(
            database,
            "SELECT status FROM astrbot_migration_batches WHERE id = ?",
            [report.batchID]
        )
        XCTAssertEqual(status, "rolled_back")

        // 不允许重复回滚
        do {
            _ = try await importer.rollback(batchID: report.batchID, at: Clock.nowMillis())
            XCTFail("重复回滚应被拒绝")
        } catch let error as AstrBotImportError {
            XCTAssertEqual(error, .alreadyRolledBack(report.batchID))
        }
    }

    // MARK: - 人格冲突不覆盖

    func testExistingCorePersonaIsNotOverwritten() async throws {
        let database = try makeDatabase("app")
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at)
            VALUES ('p-core', 'core', '大肥鱼', 1, 3, 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO persona_items (id, persona_id, section, key, value, source, updated_at)
            VALUES ('i-core', 'p-core', '核心', 'system_prompt', '原始人格，不能被覆盖。', 'user', 1)
            """)
        }

        let importer = AstrBotImporter(database: database)
        let report = try await importer.run(
            source: try makeSources(),
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(report.counts.personaRowsImported, 0)
        XCTAssertEqual(report.counts.personaPending, 1)
        let personaCount = try await count(database, "SELECT count(*) FROM personas")
        let prompt = try await string(database, "SELECT value FROM persona_items WHERE id = 'i-core'")
        XCTAssertEqual(personaCount, 1)
        XCTAssertEqual(prompt, "原始人格，不能被覆盖。")
        let conflict = try await count(
            database,
            "SELECT count(*) FROM astrbot_import_pending WHERE reason_code = 'persona_conflict'"
        )
        XCTAssertEqual(conflict, 1)
    }

    // MARK: - 源文件缺失

    func testMissingSourceFailsWithoutWritingData() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let missing = root.appendingPathComponent("not-exist.db")

        do {
            _ = try await importer.run(
                source: AstrBotSourcePaths(chatMemoryDatabase: missing),
                options: AstrBotImportOptions(isDryRun: false)
            )
            XCTFail("缺失源应失败")
        } catch let error as AstrBotImportError {
            XCTAssertEqual(error, .sourceMissing(missing.path))
        }

        let messageCount = try await count(database, "SELECT count(*) FROM messages")
        XCTAssertEqual(messageCount, 0)
        // 源缺失也要留痕
        let batchCount = try await count(database, "SELECT count(*) FROM astrbot_migration_batches")
        let batchStatus = try await string(database, "SELECT status FROM astrbot_migration_batches LIMIT 1")
        XCTAssertEqual(batchCount, 1)
        XCTAssertEqual(batchStatus, "failed")
    }
}
