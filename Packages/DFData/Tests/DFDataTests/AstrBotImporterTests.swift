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
        // 待处理合计只统计真正落库到待确认表的行：系统事件不写待确认表（避免淹没），
        // 但仍计入 messagesPending 参与覆盖校验，所以是 11 而不是 12
        XCTAssertEqual(report.counts.pendingTotal, 11)
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

    // MARK: - 导入后可见性（历史聊天必须真的能进会话）

    /// 真机反馈"导入的历史聊天不显示"：这里从仓储层完整走一遍
    /// 预演→正式导入→会话列表→消息分页，确认历史确实能被 UI 读到。
    func testImportedConversationsAreVisibleInActiveListAndMessagePage() async throws {
        let database = try makeDatabase("visible")
        let importer = AstrBotImporter(database: database)
        let source = try makeSources()

        let report = try await importer.run(source: source, options: AstrBotImportOptions(isDryRun: false))
        XCTAssertEqual(report.status, .succeeded)

        // 1) 会话列表（active）必须能取到导入会话
        let admin = GRDBConversationAdminRepository(database: database)
        let active = try await admin.list(.active)
        let imported = try XCTUnwrap(
            active.first { $0.kind == "imported" },
            "导入会话必须出现在 active 列表，实际：\(active.map { "\($0.id)/\($0.kind)" })"
        )
        XCTAssertEqual(imported.messageCount, 6)

        // 2) 进入会话后的首屏分页必须能取到历史消息，且保持原始时间升序
        let pages = GRDBMessageRepository(database: database)
        let page = try await pages.page(in: imported.id, before: nil, limit: 100)
        XCTAssertEqual(page.items.count, 6)
        XCTAssertEqual(page.items.map(\.createdAt), page.items.map(\.createdAt).sorted(), "历史消息必须按原始时间升序")
        XCTAssertTrue(page.items.allSatisfy { $0.origin == .imported })
        XCTAssertTrue(page.items.allSatisfy { $0.createdAt > 0 })

        // 3) 会话更新时间必须对齐最后一条消息，避免列表把它压到最底部
        let lastTime = try XCTUnwrap(page.items.last?.createdAt)
        XCTAssertEqual(imported.updatedAt, lastTime)
        XCTAssertEqual(imported.lastMessageAt, lastTime)
    }

    // MARK: - 待处理区

    /// 回归：真机上报过的 FOREIGN KEY constraint failed。
    /// 首启占位核心人格的 persona_items 行 id 是 UUID，而导入计划里的 id 是
    /// `astrbot-persona-item-{哈希}`。原位替换 UPDATE 命中占位行后不再 INSERT，
    /// tier_history / 映射表若仍用计划 id 就会引用不存在的行，整个导入（含预演）失败。
    func testReplacingPlaceholderCorePersonaKeepsReferentialIntegrity() async throws {
        let database = try makeDatabase("app")
        let personas = GRDBPersonaRepository(database: database)
        _ = try await personas.ensureCorePersona(
            name: "占位",
            systemPrompt: "（这是第一阶段的占位核心人格，真正的设定将在 AstrBot 迁移阶段导入。）"
        )

        let importer = AstrBotImporter(database: database)
        let report = try await importer.run(
            source: try makeSources(),
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(report.status, .succeeded)
        XCTAssertEqual(report.counts.personaRowsImported, 1)

        // 占位提示词已被 AstrBot 原文替换（原位替换，没有第二个核心人格）
        let coreCount = try await count(database, "SELECT count(*) FROM personas WHERE kind = 'core'")
        XCTAssertEqual(coreCount, 1)
        let prompt = try await personas.coreSystemPrompt()
        XCTAssertEqual(prompt, "你是鲸鱼娘，名字叫小肥。")

        // 关键回归点：tier_history 引用的 item_id 必须全部真实存在
        let dangling = try await count(
            database,
            """
            SELECT count(*) FROM persona_item_tier_history h
            LEFT JOIN persona_items i ON i.id = h.item_id
            WHERE i.id IS NULL
            """
        )
        XCTAssertEqual(dangling, 0)
    }

    func testUnknownRowsLandInPendingWithRawJSON() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let report = try await importer.run(
            source: try makeSources(),
            options: AstrBotImportOptions(isDryRun: false)
        )

        let items = try await importer.pendingItems(batchID: report.batchID, limit: 100)
        XCTAssertEqual(items.count, report.counts.pendingTotal)

        // 系统事件（进群、撤回、通知等）不写待确认表：待确认页只留真正需要人工处理的问题
        let systemEvents = items.filter { $0.reasonCode == AstrBotPendingReason.systemEvent.rawValue }
        XCTAssertTrue(systemEvents.isEmpty, "系统事件不应落库到待确认表")

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

    // MARK: - 关系账本（真实 AstrBot 结构）

    /// 富关系账本：档案分组、陪伴记忆条目、未结约定、对话剧集、违规事件、阶段上限
    private func makeRichLedger() throws -> URL {
        let url = root.appendingPathComponent("companions-rich.json")
        let ledger = """
        {"version":1,"users":{"3040525438":{
          "relationship_role":"friend",
          "relationship_positive_stage_cap_key":"close",
          "normal_interaction_band_cap":"warm",
          "relationship_score":111,
          "nickname":"3777",
          "style":"温柔",
          "last_seen":1793684159.7,
          "relationship_ledger":[
            {"event_key":"e1","reason_code":"fast_inbound","delta":1,"score_before":0,"score_after":1,"created_at":1792806466.9},
            {"event_key":"e2","reason_code":"relationship_violation","delta":-6,"score_before":20,"score_after":14,"created_at":1792900000.0}
          ],
          "companion_memory":{
            "profile":{
              "strong_memories":["大名是「泡泡」，小名是「小肥」"],
              "boundaries":["不愿做的事要明确拒绝"],
              "user_traits":["说话短，常不用标点"]
            },
            "items":[{"text":"喜欢被摸头","kind":"preference","weight":2,"created_ts":1792928813.3}],
            "items_updated_at":1792928813.3,
            "profile_updated_at":1792928813.3
          },
          "dialogue_episodes":[{
            "date":"2026-10-24",
            "created_ts":1792831007.3,
            "summary":"主人半开玩笑地把本鲸认成自己人。",
            "emotional_residue":"嘴硬的小高兴",
            "reusable_topic":"被子分你一半",
            "bot_promises":["答应分一半被子"],
            "avoid_next":["别反复追问归谁"]
          }],
          "open_loops":[{"text":"改口叫小肥还没完全兑现","status":"待自然延续","created_ts":1792839778.9}]
        }}}
        """
        try ledger.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMigratesRelationshipProfileMilestonesAndPendingProposal() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)

        let report = try await importer.run(
            source: AstrBotSourcePaths(companionLedgerJSON: try makeRichLedger()),
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(report.status, .succeeded)
        // 用户整体：已迁移，不再进待处理区
        XCTAssertEqual(report.counts.sourceLedgerUsers, 1)
        XCTAssertEqual(report.counts.relationshipUsersImported, 1)
        XCTAssertEqual(report.counts.ledgerPending, 0)
        // 关系档案 5 条（3 分组 + 1 条目 + 1 未结约定）
        XCTAssertEqual(report.counts.sourceCompanionMemories, 5)
        XCTAssertEqual(report.counts.companionMemoriesNew, 5)
        // 里程碑 2 条（1 剧集 + 1 违规）
        XCTAssertEqual(report.counts.sourceRelationshipMilestones, 2)
        XCTAssertEqual(report.counts.relationshipMilestonesNew, 2)
        XCTAssertEqual(report.counts.relationshipProposalsNew, 1)
        XCTAssertTrue(report.counts.coverageProblems.isEmpty)

        // 记忆分类：relationship / boundary / fact / preference / promise 各 1
        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 5)
        let categories = try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT category FROM memories ORDER BY category")
        }
        XCTAssertEqual(categories, ["boundary", "fact", "preference", "promise", "relationship"])
        let promiseType = try await string(
            database,
            "SELECT type FROM memories WHERE category = 'promise'"
        )
        XCTAssertEqual(promiseType, "promise")

        // 里程碑：共同经历 + 重要转折，来源一律 import
        let milestones = try await count(database, "SELECT count(*) FROM relationship_milestones")
        XCTAssertEqual(milestones, 2)
        let kinds = try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM relationship_milestones ORDER BY kind")
        }
        XCTAssertEqual(kinds, ["shared_experience", "turning_point"])
        let sources = try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT source_kind FROM relationship_milestones")
        }
        XCTAssertEqual(sources, ["import"])
        let precision = try await string(
            database,
            "SELECT time_precision FROM relationship_milestones WHERE kind = 'shared_experience'"
        )
        XCTAssertEqual(precision, "day")
        let episodeSummary = try await string(
            database,
            "SELECT summary FROM relationship_milestones WHERE kind = 'shared_experience'"
        )
        XCTAssertTrue(episodeSummary?.contains("情绪残留：嘴硬的小高兴") == true)
        XCTAssertTrue(episodeSummary?.contains("答应过：答应分一半被子") == true)

        // 阶段提案：pending，decided_by=import，绝不直接写关系档案
        let proposals = try await count(
            database,
            "SELECT count(*) FROM relationship_stage_history WHERE status = 'pending'"
        )
        XCTAssertEqual(proposals, 1)
        let toStage = try await string(database, "SELECT to_stage FROM relationship_stage_history")
        XCTAssertEqual(toStage, "close")
        let decidedBy = try await string(database, "SELECT decided_by FROM relationship_stage_history")
        XCTAssertEqual(decidedBy, "import")
        let profiles = try await count(database, "SELECT count(*) FROM relationship_profile")
        XCTAssertEqual(profiles, 0)
    }

    func testRollbackRemovesRelationshipMilestonesAndProposal() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)

        let report = try await importer.run(
            source: AstrBotSourcePaths(companionLedgerJSON: try makeRichLedger()),
            options: AstrBotImportOptions(isDryRun: false)
        )
        let rollback = try await importer.rollback(batchID: report.batchID, at: 1_800_000_000_000)

        XCTAssertEqual(rollback.deletedRelationshipMilestones, 2)
        XCTAssertEqual(rollback.deletedRelationshipProposals, 1)
        let milestones = try await count(database, "SELECT count(*) FROM relationship_milestones")
        XCTAssertEqual(milestones, 0)
        let proposals = try await count(database, "SELECT count(*) FROM relationship_stage_history")
        XCTAssertEqual(proposals, 0)
        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 0)
    }

    func testSecondImportOfRichLedgerIsIdempotent() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let ledger = try makeRichLedger()

        _ = try await importer.run(
            source: AstrBotSourcePaths(companionLedgerJSON: ledger),
            options: AstrBotImportOptions(isDryRun: false)
        )
        let second = try await importer.run(
            source: AstrBotSourcePaths(companionLedgerJSON: ledger),
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(second.counts.companionMemoriesNew, 0)
        XCTAssertEqual(second.counts.companionMemoriesDuplicate, 5)
        XCTAssertEqual(second.counts.relationshipMilestonesNew, 0)
        XCTAssertEqual(second.counts.relationshipMilestonesDuplicate, 2)
        XCTAssertEqual(second.counts.relationshipProposalsNew, 0)
        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 5)
        let milestones = try await count(database, "SELECT count(*) FROM relationship_milestones")
        XCTAssertEqual(milestones, 2)
        let proposals = try await count(database, "SELECT count(*) FROM relationship_stage_history")
        XCTAssertEqual(proposals, 1)
    }

    // MARK: - 信件去重（真实数据副本）

    func testIdenticalLetterCopiesImportOnce() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)

        let letters = root.appendingPathComponent("letters-dup", isDirectory: true)
        try FileManager.default.createDirectory(at: letters, withIntermediateDirectories: true)
        let body = "# 第一封信\n\n我会一直记得今天。"
        try body.write(to: letters.appendingPathComponent("2026-11-01.md"), atomically: true, encoding: .utf8)
        // 真实数据中 `最新一封.md` 与最近一封日期文件逐字节相同
        try body.write(to: letters.appendingPathComponent("最新一封.md"), atomically: true, encoding: .utf8)

        let report = try await importer.run(
            source: AstrBotSourcePaths(lettersDirectory: letters),
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(report.counts.sourceDocuments, 2)
        XCTAssertEqual(report.counts.documentsNew, 1)
        XCTAssertEqual(report.counts.documentsDuplicate, 1)
        XCTAssertTrue(report.counts.coverageProblems.isEmpty)

        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 1)
        let title = try await string(database, "SELECT title FROM memories")
        XCTAssertEqual(title, "第一封信")
    }

    // MARK: - 记忆脏日期（真实数据 FACTS 行）

    /// 同步构造：避免在 async 用例里落到 GRDB 的 async `write` 重载
    private func makeDirtyMemoryDatabase() throws -> URL {
        let memURL = root.appendingPathComponent("memory-dirty.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let mem = try DatabaseQueue(path: memURL.path, configuration: configuration)
        try mem.write { db in
            try db.execute(sql: "CREATE TABLE mem(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT, day TEXT, text TEXT, sig TEXT UNIQUE)")
            // 真实备份：day 列被写成 FACTS，但正文自带日期
            try db.execute(sql: """
            INSERT INTO mem (id, kind, day, text, sig)
            VALUES (1, 'diary', 'FACTS', '- 2026-10-24｜画签名时用尾巴尖蘸墨画圈', 'sig-a')
            """)
            // 真实备份：day 与正文都是 YYYY-MM-DD 占位，无法恢复日期
            try db.execute(sql: """
            INSERT INTO mem (id, kind, day, text, sig)
            VALUES (2, 'fact', 'YYYY-MM-DD', 'YYYY-MM-DD｜他帮本鲸擦身穿衣', 'sig-b')
            """)
        }
        try mem.close()
        return memURL
    }

    func testRecoversDateFromMemoryTextWhenDayColumnIsDirty() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)
        let memURL = try makeDirtyMemoryDatabase()

        let report = try await importer.run(
            source: AstrBotSourcePaths(longTermMemoryDatabase: memURL),
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(report.counts.sourceMemories, 2)
        XCTAssertEqual(report.counts.memoriesNew, 1)
        XCTAssertEqual(report.counts.memoriesPending, 1)
        XCTAssertTrue(report.counts.coverageProblems.isEmpty)

        // 恢复出的日期按 UTC+8 当天 00:00 落库
        let firstSeen = try await database.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT first_seen_at FROM memories")
        }
        XCTAssertEqual(firstSeen, 1_792_771_200_000)

        let pendings = try await importer.pendingItems(batchID: report.batchID, limit: 10)
        XCTAssertEqual(pendings.count, 1)
        XCTAssertEqual(pendings.first?.reasonCode, AstrBotPendingReason.invalidDay.rawValue)
    }

    // MARK: - 主配置留档（脱敏）

    func testConfigIsArchivedRedacted() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)

        let configURL = root.appendingPathComponent("cmd_config.json")
        let config = """
        {
          "config_version": 3,
          "agent_runner": {"config": {"model": {"provider_id": "deepseek-chat", "api_key": "sk-should-not-leak"}}},
          "provider_settings": {"websearch_baidu_app_builder_key": "secret-value"},
          "platform_settings": {"segmented_reply": {"enable": true, "interval": "1,3"}}
        }
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let report = try await importer.run(
            source: AstrBotSourcePaths(configJSON: configURL),
            options: AstrBotImportOptions(isDryRun: false)
        )

        XCTAssertEqual(report.counts.sourceConfigFiles, 1)
        XCTAssertEqual(report.counts.configPending, 1)
        XCTAssertEqual(report.counts.pendingTotal, 1)
        XCTAssertTrue(report.counts.coverageProblems.isEmpty)

        let raw = try await string(
            database,
            "SELECT raw_json FROM astrbot_import_pending WHERE entity_kind = 'config'"
        )
        XCTAssertNotNil(raw)
        XCTAssertFalse(raw?.contains("sk-should-not-leak") == true)
        XCTAssertFalse(raw?.contains("secret-value") == true)
        XCTAssertTrue(raw?.contains("<redacted>") == true)
        XCTAssertTrue(raw?.contains("deepseek-chat") == true)
        XCTAssertTrue(raw?.contains("segmented_reply") == true)
    }

    // MARK: - 关系档案同组多条（真实数据形态，防唯一索引冲突）

    func testCompanionMemoriesInSameGroupDoNotCollide() async throws {
        let database = try makeDatabase("app")
        let importer = AstrBotImporter(database: database)

        let ledgerURL = root.appendingPathComponent("companions-group.json")
        let ledger = """
        {"users":{"3040525438":{
          "relationship_positive_stage_cap_key":"close",
          "relationship_score":111,
          "last_seen":1793684159.7,
          "companion_memory":{
            "profile":{
              "strong_memories":["签名时用尾巴尖蘸墨画圈","被子分你一半的那晚"],
              "boundaries":["不愿做的事要明确拒绝"]
            },
            "items":[
              {"text":"喜欢被摸头","kind":"preference","created_ts":1792928813.3},
              {"text":"怕打雷","kind":"fact","created_ts":1792928830.1}
            ]
          },
          "open_loops":[
            {"text":"改口叫小肥还没兑现","created_ts":1792839778.9},
            {"text":"答应教他画尾巴","created_ts":1792839800.2}
          ]
        }}}
        """
        try ledger.write(to: ledgerURL, atomically: true, encoding: .utf8)

        let report = try await importer.run(
            source: AstrBotSourcePaths(companionLedgerJSON: ledgerURL),
            options: AstrBotImportOptions(isDryRun: false)
        )

        // 2 条 strong_memories + 1 条 boundaries + 2 条 items + 2 条 open_loops
        XCTAssertEqual(report.counts.sourceCompanionMemories, 7)
        XCTAssertEqual(report.counts.companionMemoriesNew, 7)
        XCTAssertEqual(report.counts.coverageProblems, [])

        let memories = try await count(database, "SELECT count(*) FROM memories")
        XCTAssertEqual(memories, 7)
        // 同一分组内 original_external_id 必须各不相同
        let uniqueSources = try await count(
            database,
            "SELECT count(DISTINCT original_external_id) FROM memories"
        )
        XCTAssertEqual(uniqueSources, 7)
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
