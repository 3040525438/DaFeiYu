import XCTest
import GRDB
import DFCore
@testable import DFData

/// 定稿事务 B / 补偿 C / 引用仓储测试（T01–T06、DB03、DB04），全部基于真实 SQLite。
final class MessageTurnRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFTurn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 环境

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
    }

    /// 建库 + 会话 + 一轮对话 + 两条可被引用的历史消息
    private func seedTurn(_ database: AppDatabase) async throws -> (group: MessageGroup, refA: String, refB: String) {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            for (id, text, millis) in [("m-a", "上周说过喜欢摄影", 500), ("m-b", "还提到养猫", 600)] {
                try db.execute(
                    sql: """
                    INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
                    VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'user', ?)
                    """,
                    arguments: [id, "uuid-\(id)", text, millis]
                )
            }
        }

        let groups = GRDBMessageGroupRepository(database: database)
        let group = try await groups.openTurn(
            OpenTurnRequest(
                group: MessageGroup(conversationID: "c1", turnIndex: 0, openedAt: 1000),
                userMessage: Message(
                    conversationID: "c1", role: .user, text: "我之前说过什么",
                    status: .sent, origin: .user, createdAt: 1000
                ),
                assistantMessage: Message(
                    conversationID: "c1", role: .assistant, text: "",
                    status: .sending, origin: .reply, createdAt: 1001
                )
            )
        )
        return (group, "m-a", "m-b")
    }

    private func reference(_ messageID: String, _ refID: String, relation: ReferenceRelation = .context) -> MessageReference {
        MessageReference(messageID: messageID, refMessageID: refID, relation: relation, createdAt: 1200)
    }

    /// 组与 assistant 的实际状态
    private func state(_ database: AppDatabase, groupID: String, assistantID: String) async throws
        -> (groupStatus: String?, closedAt: Int64?, assistantStatus: String?, text: String?, replyToID: String?) {
        try await database.dbQueue.read { db in
            let groupStatus = try String.fetchOne(
                db, sql: "SELECT status FROM message_groups WHERE id = ?", arguments: [groupID]
            )
            let closedAt = try Int64.fetchOne(
                db, sql: "SELECT closed_at FROM message_groups WHERE id = ?", arguments: [groupID]
            )
            let assistantStatus = try String.fetchOne(
                db, sql: "SELECT status FROM messages WHERE id = ?", arguments: [assistantID]
            )
            let text = try String.fetchOne(
                db, sql: "SELECT text FROM messages WHERE id = ?", arguments: [assistantID]
            )
            let replyToID = try String.fetchOne(
                db, sql: "SELECT reply_to_id FROM messages WHERE id = ?", arguments: [assistantID]
            )
            return (groupStatus, closedAt, assistantStatus, text, replyToID)
        }
    }

    // MARK: - T05 正常定稿（先跑通主路径）

    func testT05_HappyPathConsistency() async throws {
        let database = try makeDatabase("t05")
        let seeded = try await seedTurn(database)
        let turns = GRDBMessageTurnRepository(database: database)

        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: seeded.group.id,
                assistantMessageID: seeded.group.assistantMessageID!,
                text: "你上周说喜欢摄影，还养了一只猫。",
                assistantStatus: .sent,
                sentAt: 1500,
                replyToID: seeded.refA,
                references: [
                    reference(seeded.group.assistantMessageID!, seeded.refA, relation: .reply),
                    reference(seeded.group.assistantMessageID!, seeded.refB)
                ],
                groupStatus: .complete,
                closedAt: 1500
            )
        )

        let state = try await self.state(
            database,
            groupID: seeded.group.id,
            assistantID: seeded.group.assistantMessageID!
        )
        XCTAssertEqual(state.assistantStatus, "sent")
        XCTAssertEqual(state.text, "你上周说喜欢摄影，还养了一只猫。")
        XCTAssertEqual(state.replyToID, seeded.refA)
        XCTAssertEqual(state.groupStatus, "complete")
        XCTAssertEqual(state.closedAt, 1500)

        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"), 2)
        }
    }

    // MARK: - T01 assistant 定稿影响 0 行 → 整体回滚

    func testT01_FinalizeUpdateZeroRowsRollsBackB() async throws {
        let database = try makeDatabase("t01")
        let seeded = try await seedTurn(database)
        let turns = GRDBMessageTurnRepository(database: database)

        // 把 assistant 提前置为 sent，使事务 B 的定稿 UPDATE 命中 0 行
        try await database.write { db in
            try db.execute(
                sql: "UPDATE messages SET status = 'sent' WHERE id = ?",
                arguments: [seeded.group.assistantMessageID!]
            )
        }

        var thrown = false
        do {
            try await turns.finalizeTurn(
                FinalizeTurnRequest(
                    groupID: seeded.group.id,
                    assistantMessageID: seeded.group.assistantMessageID!,
                    text: "不应写入",
                    assistantStatus: .sent,
                    sentAt: 1500,
                    replyToID: seeded.refA,
                    references: [reference(seeded.group.assistantMessageID!, seeded.refA)],
                    groupStatus: .complete,
                    closedAt: 1500
                )
            )
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "定稿影响 0 行必须抛错")

        let state = try await self.state(
            database,
            groupID: seeded.group.id,
            assistantID: seeded.group.assistantMessageID!
        )
        XCTAssertEqual(state.text, "", "事务回滚后正文不得被写入")
        XCTAssertEqual(state.groupStatus, "open", "组不得被关闭")
        XCTAssertNil(state.closedAt)
        XCTAssertNil(state.replyToID, "reply_to_id 不得残留")
        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"), 0)
        }
    }

    // MARK: - T02 引用指向不存在消息 → 整体回滚

    func testT02_InvalidRefMessageRollsBackB() async throws {
        let database = try makeDatabase("t02")
        let seeded = try await seedTurn(database)
        let turns = GRDBMessageTurnRepository(database: database)

        var thrown = false
        do {
            try await turns.finalizeTurn(
                FinalizeTurnRequest(
                    groupID: seeded.group.id,
                    assistantMessageID: seeded.group.assistantMessageID!,
                    text: "引用不存在",
                    assistantStatus: .sent,
                    sentAt: 1500,
                    replyToID: nil,
                    references: [reference(seeded.group.assistantMessageID!, "ghost")],
                    groupStatus: .complete,
                    closedAt: 1500
                )
            )
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "外键指向不存在消息必须失败")

        let state = try await self.state(
            database,
            groupID: seeded.group.id,
            assistantID: seeded.group.assistantMessageID!
        )
        XCTAssertEqual(state.assistantStatus, "sending", "assistant 必须回滚为 sending")
        XCTAssertEqual(state.text, "")
        XCTAssertEqual(state.groupStatus, "open")
        XCTAssertNil(state.closedAt)
        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"), 0)
        }
    }

    // MARK: - T03 第 3 条引用失败 → 前 2 条也不落库

    func testT03_ThirdReferenceFailureRollsBackAll() async throws {
        let database = try makeDatabase("t03")
        let seeded = try await seedTurn(database)
        let turns = GRDBMessageTurnRepository(database: database)

        var thrown = false
        do {
            try await turns.finalizeTurn(
                FinalizeTurnRequest(
                    groupID: seeded.group.id,
                    assistantMessageID: seeded.group.assistantMessageID!,
                    text: "部分引用",
                    assistantStatus: .sent,
                    sentAt: 1500,
                    replyToID: seeded.refA,
                    references: [
                        reference(seeded.group.assistantMessageID!, seeded.refA, relation: .reply),
                        reference(seeded.group.assistantMessageID!, seeded.refB),
                        reference(seeded.group.assistantMessageID!, "ghost")
                    ],
                    groupStatus: .complete,
                    closedAt: 1500
                )
            )
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown)

        try await database.dbQueue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"),
                0,
                "前两条合法引用也必须随事务回滚"
            )
        }
        let state = try await self.state(
            database,
            groupID: seeded.group.id,
            assistantID: seeded.group.assistantMessageID!
        )
        XCTAssertEqual(state.assistantStatus, "sending")
        XCTAssertEqual(state.groupStatus, "open")
        XCTAssertNil(state.replyToID)
    }

    // MARK: - T04 回滚后无残留（四条不变量）

    func testT04_NoResidueAfterRollback() async throws {
        let database = try makeDatabase("t04")
        let seeded = try await seedTurn(database)
        let turns = GRDBMessageTurnRepository(database: database)

        _ = try? await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: seeded.group.id,
                assistantMessageID: seeded.group.assistantMessageID!,
                text: "失败定稿",
                assistantStatus: .sent,
                sentAt: 1500,
                replyToID: seeded.refA,
                references: [reference(seeded.group.assistantMessageID!, "ghost")],
                groupStatus: .complete,
                closedAt: 1500
            )
        )

        try await database.dbQueue.read { db in
            // ① 没有"已 sent 但无引用/组未关"的记录
            let orphanSent = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messages m JOIN message_groups g ON g.id = m.group_id
                WHERE m.role = 'assistant' AND m.status = 'sent' AND g.status = 'open'
                """)
            XCTAssertEqual(orphanSent, 0)

            // ② 没有"组已 complete 但 assistant 未 sent"
            let badComplete = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message_groups g JOIN messages m ON m.id = g.assistant_message_id
                WHERE g.status = 'complete' AND m.status <> 'sent'
                """)
            XCTAssertEqual(badComplete, 0)

            // ③ 没有指向不存在消息的引用
            let dangling = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message_references r
                LEFT JOIN messages m ON m.id = r.ref_message_id WHERE m.id IS NULL
                """)
            XCTAssertEqual(dangling, 0)

            // ④ 终态组必须写 closed_at
            let missingClosedAt = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM message_groups WHERE status <> 'open' AND closed_at IS NULL
                """)
            XCTAssertEqual(missingClosedAt, 0)
        }
    }

    // MARK: - T06 补偿事务 C

    func testT06_CompensationTransactionC() async throws {
        let database = try makeDatabase("t06")
        let seeded = try await seedTurn(database)
        let turns = GRDBMessageTurnRepository(database: database)

        // 事务 B 失败
        _ = try? await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: seeded.group.id,
                assistantMessageID: seeded.group.assistantMessageID!,
                text: "失败内容",
                assistantStatus: .sent,
                sentAt: 1500,
                replyToID: nil,
                references: [reference(seeded.group.assistantMessageID!, "ghost")],
                groupStatus: .complete,
                closedAt: 1500
            )
        )

        // 事务 C 收尾
        try await turns.failTurn(
            groupID: seeded.group.id,
            assistantMessageID: seeded.group.assistantMessageID!,
            text: "失败内容",
            closedAt: 1600
        )

        let state = try await self.state(
            database,
            groupID: seeded.group.id,
            assistantID: seeded.group.assistantMessageID!
        )
        XCTAssertEqual(state.assistantStatus, "failed")
        XCTAssertEqual(state.text, "失败内容", "补偿事务可保留失败正文")
        XCTAssertEqual(state.groupStatus, "failed")
        XCTAssertEqual(state.closedAt, 1600)
        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"), 0)
        }
    }

    // MARK: - DB03 引用批量写入幂等

    func testDB03_BatchReferenceInsertIdempotent() async throws {
        let database = try makeDatabase("db03")
        let seeded = try await seedTurn(database)
        let repository = GRDBMessageReferenceRepository(database: database)
        let assistantID = seeded.group.assistantMessageID!

        let batch = [
            reference(assistantID, seeded.refA, relation: .reply),
            reference(assistantID, seeded.refB),
            reference(assistantID, seeded.refA)
        ]
        try await repository.insertBatch(batch)
        try await repository.insertBatch(batch)

        let stored = try await repository.references(for: [assistantID])
        XCTAssertEqual(stored.count, 2, "复合主键冲突必须幂等忽略，重复批次不得膨胀")

        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"), 2)
        }
    }

    // MARK: - DB04 物理删除级联清理引用

    func testDB04_CascadeDeleteReference() async throws {
        let database = try makeDatabase("db04")
        let seeded = try await seedTurn(database)
        let repository = GRDBMessageReferenceRepository(database: database)
        let assistantID = seeded.group.assistantMessageID!

        try await repository.insertBatch([
            reference(assistantID, seeded.refA, relation: .reply),
            reference(assistantID, seeded.refB)
        ])
        let before = try await repository.references(for: [assistantID])
        XCTAssertEqual(before.count, 2)

        // 仅测试库：物理删除被引用消息，引用必须级联清除
        try await database.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [seeded.refA])
        }

        try await database.dbQueue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references WHERE ref_message_id = ?", arguments: [seeded.refA]),
                0
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"), 1)
        }
    }
}
