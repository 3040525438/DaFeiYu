import XCTest
import GRDB
import DFCore
@testable import DFData

/// 消息组仓储测试（M13–M22、DB01、DB02），全部基于真实 SQLite。
final class MessageGroupRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFGroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 辅助

    private func makeDatabase(_ name: String) throws -> AppDatabase {
        try AppDatabase(paths: DatabasePaths(root: root.appendingPathComponent(name, isDirectory: true)))
    }

    private func seedConversation(_ database: AppDatabase, id: String = "c1") async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversations (id, title, kind, created_at, updated_at)
                VALUES (?, '大肥鱼', 'main', 1, 1)
                """,
                arguments: [id]
            )
        }
    }

    private func makeRequest(
        conversationID: String = "c1",
        at millis: Int64 = 1000,
        userText: String = "在吗",
        assistantText: String = ""
    ) -> OpenTurnRequest {
        OpenTurnRequest(
            group: MessageGroup(conversationID: conversationID, turnIndex: 0, openedAt: millis),
            userMessage: Message(
                conversationID: conversationID,
                role: .user,
                text: userText,
                status: .sent,
                origin: .user,
                createdAt: millis
            ),
            assistantMessage: Message(
                conversationID: conversationID,
                role: .assistant,
                text: assistantText,
                status: .sending,
                origin: .reply,
                createdAt: millis + 1
            )
        )
    }

    /// 14 列真实值快照（quote 后可区分 NULL 与空串）
    private func rowLines(_ database: AppDatabase, where clause: String = "1=1") async throws -> [String] {
        let columns = V3Chat.legacyColumns.map { "quote(\($0))" }.joined(separator: " || char(31) || ")
        return try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT \(columns) AS line FROM messages WHERE \(clause) ORDER BY id")
        }
    }

    /// 并发测试用：不捕获 self，避免测试类在并发闭包中的 Sendable 捕获
    private static func attemptOpen(_ repository: GRDBMessageGroupRepository, at millis: Int64) async -> Bool {
        let request = OpenTurnRequest(
            group: MessageGroup(conversationID: "c1", turnIndex: 0, openedAt: millis),
            userMessage: Message(
                conversationID: "c1", role: .user, text: "并发",
                status: .sent, origin: .user, createdAt: millis
            ),
            assistantMessage: Message(
                conversationID: "c1", role: .assistant, text: "",
                status: .sending, origin: .reply, createdAt: millis + 1
            )
        )
        do {
            _ = try await repository.openTurn(request)
            return true
        } catch {
            return false
        }
    }

    // MARK: - M13 真实 SQL 计算轮次

    func testM13_MaxTurnIndexFromSQL() async throws {
        let database = try makeDatabase("m13")
        try await seedConversation(database)
        let repository = GRDBMessageGroupRepository(database: database)

        let empty = try await repository.maxTurnIndex(in: "c1")
        XCTAssertNil(empty)

        var indices: [Int] = []
        for step in 0..<3 {
            let group = try await repository.openTurn(
                makeRequest(at: Int64(1000 + step * 10), userText: "第\(step)轮")
            )
            indices.append(group.turnIndex)
        }
        XCTAssertEqual(indices, [1, 2, 3])

        let maxIndex = try await repository.maxTurnIndex(in: "c1")
        XCTAssertEqual(maxIndex, 3)
    }

    // MARK: - M14 轮次唯一索引拒绝重号

    func testM14_DuplicateTurnRollsBackWholeGroup() async throws {
        let database = try makeDatabase("m14")
        try await seedConversation(database)
        let repository = GRDBMessageGroupRepository(database: database)

        _ = try await repository.openTurn(makeRequest(at: 1000))

        // 直接插入同轮次组：必须被唯一索引拒绝，且不留半条记录
        var thrown = false
        do {
            try await database.write { db in
                try db.execute(sql: """
                INSERT INTO message_groups (id, conversation_id, turn_index, kind, status, opened_at)
                VALUES ('dup', 'c1', 1, 'chat', 'open', 2000)
                """)
            }
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "重复 turn_index 必须被唯一索引拒绝")

        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_groups WHERE turn_index = 1"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_groups WHERE id = 'dup'"), 0)
        }
    }

    // MARK: - M15 取消不改成员正文

    func testM15_CancelKeepsMessageContent() async throws {
        let database = try makeDatabase("m15")
        try await seedConversation(database)
        let repository = GRDBMessageGroupRepository(database: database)

        let group = try await repository.openTurn(
            makeRequest(at: 1000, userText: "写首诗", assistantText: "床前明月")
        )

        let userBefore = try await rowLines(database, where: "role = 'user'")
        try await repository.cancelTurn(
            groupID: group.id,
            assistantMessageID: group.assistantMessageID!,
            closedAt: 3000
        )
        let userAfter = try await rowLines(database, where: "role = 'user'")

        XCTAssertEqual(userAfter, userBefore, "用户消息 14 列必须逐字段不变")

        try await database.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM messages WHERE id = ?",
                arguments: [group.assistantMessageID!]
            )
            let sentAt = try Int64.fetchOne(
                db,
                sql: "SELECT sent_at FROM messages WHERE id = ?",
                arguments: [group.assistantMessageID!]
            )
            XCTAssertEqual(try row?.decode(String.self, forColumn: "text"), "床前明月")
            XCTAssertNil(sentAt, "取消不得写 sent_at")
            XCTAssertEqual(try row?.decode(String.self, forColumn: "status"), "canceled")
            // 序号与分组不被取消操作改变
            XCTAssertEqual(try row?.decode(Int.self, forColumn: "seq_in_group"), 1)
            XCTAssertEqual(try row?.decode(String.self, forColumn: "group_id"), group.id)
        }
    }

    // MARK: - M16 双连接并发开组

    func testM16_ConcurrentOpenTwoConnections() async throws {
        let directory = root.appendingPathComponent("m16", isDirectory: true)
        let first = try AppDatabase(paths: DatabasePaths(root: directory))
        try await seedConversation(first)
        // 第二个连接指向同一文件（各自独立的 DatabaseQueue）
        let second = try AppDatabase(paths: DatabasePaths(root: directory))

        let repositoryA = GRDBMessageGroupRepository(database: first)
        let repositoryB = GRDBMessageGroupRepository(database: second)

        async let firstSucceeded = Self.attemptOpen(repositoryA, at: 1000)
        async let secondSucceeded = Self.attemptOpen(repositoryB, at: 1001)
        let outcomes = [await firstSucceeded, await secondSucceeded]

        XCTAssertTrue(outcomes.contains(true), "至少有一个连接成功开组")

        try await first.dbQueue.read { db in
            let indices = try Int.fetchAll(db, sql: "SELECT turn_index FROM message_groups ORDER BY turn_index")
            XCTAssertEqual(indices, Array(Set(indices)).sorted(), "turn_index 不得重复")
            XCTAssertFalse(indices.isEmpty)
            // 每个组都必须有成对消息，不允许半组
            for index in indices {
                let paired = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT count(*) FROM messages m
                    JOIN message_groups g ON g.id = m.group_id
                    WHERE g.turn_index = ? AND g.conversation_id = 'c1'
                    """,
                    arguments: [index]
                )
                XCTAssertEqual(paired, 2, "第 \(index) 轮必须有 user + assistant 两条")
            }
        }
    }

    // MARK: - M17 取消持久化

    func testM17_CancelPersistsAbortedGroup() async throws {
        let database = try makeDatabase("m17")
        try await seedConversation(database)
        let repository = GRDBMessageGroupRepository(database: database)

        let group = try await repository.openTurn(makeRequest(at: 1000, assistantText: "半句"))
        try await repository.cancelTurn(
            groupID: group.id,
            assistantMessageID: group.assistantMessageID!,
            closedAt: 5000
        )

        let stored = try await repository.group(id: group.id)
        XCTAssertEqual(stored?.status, .aborted)
        XCTAssertEqual(stored?.closedAt, 5000)
        XCTAssertFalse(stored?.isMissingClosedAt ?? true)

        let status = try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM messages WHERE id = ?", arguments: [group.assistantMessageID!])
        }
        XCTAssertEqual(status, "canceled")
    }

    // MARK: - M18 失败持久化

    func testM18_FailurePersistsFailedGroup() async throws {
        let database = try makeDatabase("m18")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)
        let turns = GRDBMessageTurnRepository(database: database)

        let group = try await groups.openTurn(makeRequest(at: 1000))
        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: group.id,
                assistantMessageID: group.assistantMessageID!,
                text: "",
                assistantStatus: .failed,
                sentAt: nil,
                replyToID: nil,
                references: [],
                groupStatus: .failed,
                closedAt: 4000
            )
        )

        let stored = try await groups.group(id: group.id)
        XCTAssertEqual(stored?.status, .failed)
        XCTAssertEqual(stored?.closedAt, 4000)

        try await database.dbQueue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM messages WHERE id = ?", arguments: [group.assistantMessageID!]),
                "failed"
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_references"), 0)
        }
    }

    // MARK: - M19 重试开新组

    func testM19_RetryCreatesNewGroup() async throws {
        let database = try makeDatabase("m19")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)
        let turns = GRDBMessageTurnRepository(database: database)

        // 场景一：失败的组重试 → 旧组 aborted，新组轮次 +1
        let first = try await groups.openTurn(makeRequest(at: 1000))
        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: first.id,
                assistantMessageID: first.assistantMessageID!,
                text: "",
                assistantStatus: .failed,
                sentAt: nil,
                replyToID: nil,
                references: [],
                groupStatus: .aborted,
                closedAt: 2000
            )
        )
        let retry = try await groups.openTurn(makeRequest(at: 2100))
        XCTAssertEqual(retry.turnIndex, first.turnIndex + 1)
        let firstAfter = try await groups.group(id: first.id)
        XCTAssertEqual(firstAfter?.status, .aborted)

        // 场景二：complete 组再发新消息 → 旧组保持 complete，新组轮次 +1
        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: retry.id,
                assistantMessageID: retry.assistantMessageID!,
                text: "好的",
                assistantStatus: .sent,
                sentAt: 2500,
                replyToID: nil,
                references: [],
                groupStatus: .complete,
                closedAt: 2500
            )
        )
        let next = try await groups.openTurn(makeRequest(at: 2600))
        XCTAssertEqual(next.turnIndex, retry.turnIndex + 1)
        let retryAfter = try await groups.group(id: retry.id)
        XCTAssertEqual(retryAfter?.status, .complete, "complete 组不得被后续轮次改写")
    }

    // MARK: - M20 终态组不可取消

    func testM20_CancelRejectedForTerminalGroup() async throws {
        let database = try makeDatabase("m20")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)
        let turns = GRDBMessageTurnRepository(database: database)

        let group = try await groups.openTurn(makeRequest(at: 1000))
        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: group.id,
                assistantMessageID: group.assistantMessageID!,
                text: "完成",
                assistantStatus: .sent,
                sentAt: 1200,
                replyToID: nil,
                references: [],
                groupStatus: .complete,
                closedAt: 1200
            )
        )

        var thrown = false
        do {
            try await groups.cancelTurn(
                groupID: group.id,
                assistantMessageID: group.assistantMessageID!,
                closedAt: 9000
            )
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "complete 组不得被普通取消改成 aborted")

        let stored = try await groups.group(id: group.id)
        XCTAssertEqual(stored?.status, .complete)
        XCTAssertEqual(stored?.closedAt, 1200)

        let status = try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM messages WHERE id = ?", arguments: [group.assistantMessageID!])
        }
        XCTAssertEqual(status, "sent")
    }

    // MARK: - M21 陈旧 sending 修复

    func testM21_StaleSendingRecovery() async throws {
        let database = try makeDatabase("m21")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)
        let turns = GRDBMessageTurnRepository(database: database)

        // 一个残留 open 组（assistant 停在 sending）
        let stale = try await groups.openTurn(makeRequest(at: 1000))
        // 一个已完成的终态组（不得被修复影响）
        let done = try await groups.openTurn(makeRequest(at: 2000))
        try await turns.finalizeTurn(
            FinalizeTurnRequest(
                groupID: done.id,
                assistantMessageID: done.assistantMessageID!,
                text: "完成",
                assistantStatus: .sent,
                sentAt: 2100,
                replyToID: nil,
                references: [],
                groupStatus: .complete,
                closedAt: 2100
            )
        )

        let repaired = try await groups.repairStaleSending(in: "c1")
        XCTAssertEqual(repaired, 1, "只修复残留的 sending")

        let staleGroup = try await groups.group(id: stale.id)
        XCTAssertEqual(staleGroup?.status, .failed)
        XCTAssertNotNil(staleGroup?.closedAt)

        try await database.dbQueue.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM messages WHERE id = ?", arguments: [stale.assistantMessageID!]),
                "failed"
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT status FROM messages WHERE id = ?", arguments: [done.assistantMessageID!]),
                "sent"
            )
        }

        // 幂等：再次执行不产生任何变化
        let again = try await groups.repairStaleSending(in: "c1")
        XCTAssertEqual(again, 0)
        let doneAfter = try await groups.group(id: done.id)
        XCTAssertEqual(doneAfter?.closedAt, 2100)
        XCTAssertEqual(doneAfter?.status, .complete)
    }

    // MARK: - DB01 组 CRUD

    func testDB01_GroupCRUD() async throws {
        let database = try makeDatabase("db01")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)

        let group = try await groups.openTurn(makeRequest(at: 1000))
        let fetched = try await groups.group(id: group.id)
        XCTAssertEqual(fetched?.id, group.id)
        let open = try await groups.openGroup(in: "c1")
        XCTAssertEqual(open?.id, group.id)

        // closeGroup 是事务 B 的组成部分：调用前成员状态已由调用方写好
        try await database.write { db in
            try db.execute(
                sql: "UPDATE messages SET status = 'failed' WHERE id = ?",
                arguments: [group.assistantMessageID!]
            )
        }
        try await groups.closeGroup(id: group.id, status: .failed, closedAt: 3000)
        let openAfter = try await groups.openGroup(in: "c1")
        XCTAssertNil(openAfter)
        let closed = try await groups.group(id: group.id)
        XCTAssertEqual(closed?.status, .failed)
        XCTAssertEqual(closed?.closedAt, 3000)

        var thrown = false
        do {
            try await groups.closeGroup(id: group.id, status: .complete, closedAt: 4000)
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "终态组不可再次关闭")
    }

    // MARK: - DB02 同一事务内重复开组

    func testDB02_DuplicateOpenInSameTransaction() async throws {
        let database = try makeDatabase("db02")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)

        _ = try await groups.openTurn(makeRequest(at: 1000))

        var thrown = false
        do {
            try await database.write { db in
                try db.execute(sql: """
                INSERT INTO message_groups (id, conversation_id, turn_index, kind, status, opened_at)
                VALUES ('g-dup-a', 'c1', 2, 'chat', 'open', 2000)
                """)
                try db.execute(sql: """
                INSERT INTO message_groups (id, conversation_id, turn_index, kind, status, opened_at)
                VALUES ('g-dup-b', 'c1', 2, 'chat', 'open', 2001)
                """)
            }
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "同一事务内重复轮次必须失败")

        try await database.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_groups WHERE turn_index = 2"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message_groups"), 1)
        }
    }

    // MARK: - M22 软删占位 seq + 部分唯一索引拒绝重复

    /// 证明两件互相独立的事：
    /// A. `max(seq_in_group)` 不过滤 `deleted_at`，软删消息仍占位（否则会重用历史序号）；
    /// B. `ux_messages_group_seq` 作为部分唯一索引，真实拒绝同组重复序号。
    ///
    /// 全程使用临时文件 SQLite（`AppDatabase` 真实建库 + 真实迁移），不 mock 仓储。
    func testM22_SoftDeletedSeqOccupiedAndPartialUniqueIndexRejectsDuplicate() async throws {
        let database = try makeDatabase("m22")
        try await seedConversation(database)
        let groups = GRDBMessageGroupRepository(database: database)

        // 1. 创建消息组：openTurn 在同一事务内写入 seq 0（user）与 seq 1（assistant）
        let group = try await groups.openTurn(makeRequest(at: 1000, userText: "问", assistantText: "答"))
        let userID = try XCTUnwrap(group.userMessageID)
        let assistantID = try XCTUnwrap(group.assistantMessageID)

        // 2. 在组内再写入一条 seq_in_group = 2 的消息（走真实记录层 Message.insert）
        let third = Message(
            conversationID: "c1",
            role: .assistant,
            text: "第三条",
            status: .sent,
            origin: .reply,
            createdAt: 1002,
            sentAt: 1002,
            groupID: group.id,
            seqInGroup: 2
        )
        try await database.write { db in try third.insert(db) }

        // 其他消息（seq 0 / 1）的 14 列快照，用于最后证明未被本次操作修改
        let othersBefore = try await rowLines(
            database,
            where: "id IN ('\(userID)', '\(assistantID)')"
        )

        // 3. 软删除 seq_in_group = 2 的消息
        try await database.write { db in
            try db.execute(
                sql: "UPDATE messages SET deleted_at = 3000 WHERE id = ?",
                arguments: [third.id]
            )
        }

        // 4. A：真实查询 max(seq_in_group)，软删消息仍在计数内 → 必须为 2
        let maxSeq = try await database.dbQueue.read { db in
            try GRDBMessageGroupRepository.maxSeqValue(db, groupID: group.id)
        }
        XCTAssertEqual(maxSeq, 2, "max(seq_in_group) 必须包含已软删消息（不得按有效条数回退到 1）")

        // 5. 用真实序号分配逻辑算出下一条序号，并真正写库
        let nextSeq = GroupPlanner.nextSeq(afterMaxExisting: maxSeq)
        XCTAssertEqual(nextSeq, 3, "软删占位后下一条必须是 3，不能重用 2")
        let fourth = Message(
            conversationID: "c1",
            role: .assistant,
            text: "第四条",
            status: .sent,
            origin: .reply,
            createdAt: 1003,
            sentAt: 1003,
            groupID: group.id,
            seqInGroup: nextSeq
        )
        try await database.write { db in try fourth.insert(db) }

        // 6./7. B：同组再次插入 seq_in_group = 2，必须被部分唯一索引拒绝
        var conflictMessage: String?
        do {
            try await database.write { db in
                try Message(
                    conversationID: "c1",
                    role: .assistant,
                    text: "冲突",
                    status: .sent,
                    origin: .reply,
                    createdAt: 1004,
                    groupID: group.id,
                    seqInGroup: 2
                ).insert(db)
            }
            XCTFail("同组重复 seq_in_group 必须抛错")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT, "必须是约束冲突，实际：\(error)")
            conflictMessage = error.message
        } catch {
            XCTFail("应抛 DatabaseError，实际：\(error)")
        }
        XCTAssertTrue(
            conflictMessage?.contains("seq_in_group") == true,
            "必须由 ux_messages_group_seq 拦截，实际错误：\(conflictMessage ?? "nil")"
        )

        // 8. 数据库终态
        try await database.dbQueue.read { db in
            // 软删的 seq=2 记录仍存在，且字段未被失败插入改写
            let soft = try Row.fetchOne(
                db,
                sql: "SELECT text, deleted_at FROM messages WHERE id = ?",
                arguments: [third.id]
            )
            XCTAssertEqual(try soft?.decode(String.self, forColumn: "text"), "第三条")
            XCTAssertEqual(try soft?.decode(Int64.self, forColumn: "deleted_at"), 3000)

            // seq=2 全组只有 1 条（就是那条软删的），不存在第二条
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM messages WHERE group_id = ? AND seq_in_group = 2",
                    arguments: [group.id]
                ),
                1,
                "冲突插入必须整体回滚，不得留下第二条 seq=2"
            )
            // seq=3 已写入
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM messages WHERE group_id = ? AND seq_in_group = 3",
                    arguments: [group.id]
                ),
                1
            )
            // 组内消息总数 = 0/1/2(软删)/3 共 4 条
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM messages WHERE group_id = ?",
                    arguments: [group.id]
                ),
                4
            )
        }

        // 其他消息 14 列逐字段未变
        let othersAfter = try await rowLines(
            database,
            where: "id IN ('\(userID)', '\(assistantID)')"
        )
        XCTAssertEqual(othersAfter, othersBefore, "seq 0/1 的消息不得被本次操作修改")
    }
}
