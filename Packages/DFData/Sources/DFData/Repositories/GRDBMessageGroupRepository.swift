import Foundation
import GRDB
import DFCore

/// 消息组仓储实现。
///
/// 设计约束（r2.2.1 / A2）：
/// - 事务 A（开组）在**一个写事务**内完成"算轮次 → 插入组 → 插入 user → 插入 assistant"；
/// - `turn_index` 的原子性由本方法的写事务 + `ux_message_groups_turn` 唯一索引共同保证；
/// - 组内序号的**规则**来自 `GroupPlanner.nextSeq(afterMaxExisting:)`，**取值**来自真实 SQL；
/// - 陈旧 `sending` 修复必须在同一事务内同时更新消息与组，且重复执行安全。
public struct GRDBMessageGroupRepository: MessageGroupRepository, StaleTurnRecoveryRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 事务 A：开组

    public func openTurn(_ request: OpenTurnRequest) async throws -> MessageGroup {
        do {
            return try await database.write { db in
                // 1. 同一写事务内取当前最大轮次，唯一索引再兜底并发重号
                let maxTurn = try Int.fetchOne(
                    db,
                    sql: "SELECT max(turn_index) FROM message_groups WHERE conversation_id = ?",
                    arguments: [request.group.conversationID]
                )
                var group = request.group
                group.turnIndex = GroupPlanner.nextTurnIndex(after: maxTurn)
                group.status = .open
                group.closedAt = nil
                try group.insert(db)

                // 2. 用户消息：seq 由真实 MAX 查询 + 纯逻辑规则共同决定
                var user = request.userMessage
                user.groupID = group.id
                user.seqInGroup = GroupPlanner.nextSeq(
                    afterMaxExisting: try Self.maxSeqValue(db, groupID: group.id)
                )
                try user.insert(db)

                // 3. assistant 消息：同一事务内再次查询，保证不与前一条重号
                var assistant = request.assistantMessage
                assistant.groupID = group.id
                assistant.seqInGroup = GroupPlanner.nextSeq(
                    afterMaxExisting: try Self.maxSeqValue(db, groupID: group.id)
                )
                try assistant.insert(db)

                // 4. 全文索引：开组阶段先索引用户输入（assistant 正文在事务 B 索引）
                try MessageIndexer.index(
                    db: db,
                    messageID: user.id,
                    conversationID: request.group.conversationID,
                    text: user.text
                )

                group.userMessageID = user.id
                group.assistantMessageID = assistant.id
                try group.update(db)
                return group
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    /// 组内最大序号。**故意不过滤 `deleted_at`**：软删消息仍占用序号，
    /// 否则按有效条数计算会在软删后重用历史序号并与唯一索引冲突。
    static func maxSeqValue(_ db: Database, groupID: String) throws -> Int? {
        try Int.fetchOne(
            db,
            sql: "SELECT max(seq_in_group) FROM messages WHERE group_id = ?",
            arguments: [groupID]
        )
    }

    // MARK: - 查询

    public func group(id: String) async throws -> MessageGroup? {
        do {
            return try await database.dbQueue.read { db in
                try MessageGroup.fetchOne(db, key: id)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func openGroup(in conversationID: String) async throws -> MessageGroup? {
        do {
            return try await database.dbQueue.read { db in
                try MessageGroup
                    .filter(Column("conversation_id") == conversationID)
                    .filter(Column("status") == MessageGroupStatus.open.rawValue)
                    .fetchOne(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func maxTurnIndex(in conversationID: String) async throws -> Int? {
        do {
            return try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT max(turn_index) FROM message_groups WHERE conversation_id = ?",
                    arguments: [conversationID]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func maxSeq(inGroup groupID: String) async throws -> Int? {
        do {
            return try await database.dbQueue.read { db in
                try Self.maxSeqValue(db, groupID: groupID)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 关组

    public func closeGroup(id: String, status: MessageGroupStatus, closedAt: Int64) async throws {
        guard GroupPlanner.canTransition(.open, to: status), status != .open else {
            throw DFError.database("非法的组状态转移：open → \(status.rawValue)")
        }
        do {
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE message_groups SET status = ?, closed_at = ? WHERE id = ? AND status = 'open'",
                    arguments: [status.rawValue, closedAt, id]
                )
                guard db.changesCount == 1 else {
                    throw DFError.database("消息组不存在或已是终态，无法关闭：\(id)")
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 取消（仅 open）

    public func cancelTurn(groupID: String, assistantMessageID: String, closedAt: Int64) async throws {
        do {
            try await database.write { db in
                guard let group = try MessageGroup.fetchOne(db, key: groupID) else {
                    throw DFError.database("消息组不存在：\(groupID)")
                }
                // 终态组不可再次取消（complete 绝不因普通取消变成 aborted）
                guard GroupPlanner.shouldAbortOnCancel(group.status) else {
                    throw DFError.database(
                        "消息组状态为 \(group.status.rawValue)，不可取消（仅 open 可取消）"
                    )
                }

                // assistant 保留已生成正文，不写 sent_at
                try db.execute(
                    sql: """
                    UPDATE messages SET status = ?
                    WHERE id = ? AND status = 'sending' AND group_id = ?
                    """,
                    arguments: [MessageStatus.canceled.rawValue, assistantMessageID, groupID]
                )
                guard db.changesCount == 1 else {
                    throw DFError.database("assistant 消息不在可取消状态：\(assistantMessageID)")
                }

                try db.execute(
                    sql: "UPDATE message_groups SET status = ?, closed_at = ? WHERE id = ? AND status = 'open'",
                    arguments: [MessageGroupStatus.aborted.rawValue, closedAt, groupID]
                )
                guard db.changesCount == 1 else {
                    throw DFError.database("消息组状态已变化，取消失败：\(groupID)")
                }

                // 组合合法性自检：aborted + canceled 必须是方案允许的组合
                guard GroupPlanner.isValidCombination(group: .aborted, assistant: .canceled) else {
                    throw DFError.database("取消后的组/消息状态组合不合法")
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    // MARK: - 陈旧 sending 修复

    public func repairStaleSending(in conversationID: String) async throws -> Int {
        let now = Clock.nowMillis()
        do {
            return try await database.write { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, group_id FROM messages
                    WHERE conversation_id = ? AND status = 'sending' AND deleted_at IS NULL
                    ORDER BY created_at ASC
                    """,
                    arguments: [conversationID]
                )
                var repaired = 0
                for row in rows {
                    let messageID = try row.decode(String.self, forColumn: "id")
                    let groupID = String.fromDatabaseValue(row["group_id"])

                    try db.execute(
                        sql: "UPDATE messages SET status = 'failed' WHERE id = ? AND status = 'sending'",
                        arguments: [messageID]
                    )
                    guard db.changesCount == 1 else { continue }

                    // 仅 open 组跟随转为 failed；complete / failed / aborted 一律不动
                    if let groupID {
                        try db.execute(
                            sql: """
                            UPDATE message_groups SET status = 'failed', closed_at = ?
                            WHERE id = ? AND status = 'open'
                            """,
                            arguments: [now, groupID]
                        )
                    }
                    repaired += 1
                }
                return repaired
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    /// 带排除能力的陈旧轮次修复（S4-A）。语义与 `repairStaleSending` 一致，
    /// 仅多一个 `excludingGroupID`：该组的消息与组本身都不被修改，避免误伤正在生成的轮次。
    public func repairStaleTurns(
        in conversationID: String,
        excludingGroupID: String?
    ) async throws -> StaleTurnRepairResult {
        let now = Clock.nowMillis()
        do {
            return try await database.write { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, group_id FROM messages
                    WHERE conversation_id = ? AND status = 'sending' AND deleted_at IS NULL
                      AND (? IS NULL OR group_id IS NULL OR group_id <> ?)
                    ORDER BY created_at ASC
                    """,
                    arguments: [conversationID, excludingGroupID, excludingGroupID]
                )
                var repaired = 0
                var closed = 0
                for row in rows {
                    let messageID = try row.decode(String.self, forColumn: "id")
                    let groupID = String.fromDatabaseValue(row["group_id"])

                    try db.execute(
                        sql: "UPDATE messages SET status = 'failed' WHERE id = ? AND status = 'sending'",
                        arguments: [messageID]
                    )
                    guard db.changesCount == 1 else { continue }
                    repaired += 1

                    // 仅 open 组跟随转为 failed；终态组一律不动；活跃组已在上面的 SELECT 中排除
                    if let groupID {
                        try db.execute(
                            sql: """
                            UPDATE message_groups SET status = 'failed', closed_at = ?
                            WHERE id = ? AND status = 'open'
                            """,
                            arguments: [now, groupID]
                        )
                        if db.changesCount == 1 { closed += 1 }
                    }
                }
                // ---- S4-B：组级残留兜底 ----
                // 只处理仍然 open 的组，且目标状态由"消息真实状态"决定，
                // 不做"所有 open 一律 failed"的粗暴降级。
                let orphans = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT g.id AS gid,
                           (SELECT m.status FROM messages m
                             WHERE m.group_id = g.id AND m.role = 'assistant'
                             ORDER BY m.seq_in_group ASC LIMIT 1) AS ast_any,
                           (SELECT m.status FROM messages m
                             WHERE m.group_id = g.id AND m.role = 'assistant'
                               AND m.deleted_at IS NULL
                             ORDER BY m.seq_in_group ASC LIMIT 1) AS ast_visible
                    FROM message_groups g
                    WHERE g.conversation_id = ? AND g.status = 'open'
                      AND (? IS NULL OR g.id <> ?)
                    """,
                    arguments: [conversationID, excludingGroupID, excludingGroupID]
                )
                for row in orphans {
                    let groupID = try row.decode(String.self, forColumn: "gid")
                    // ast_any：不过滤软删，用于区分"根本没有 assistant 行"
                    let anyStatus = String.fromDatabaseValue(row["ast_any"])
                    // ast_visible：只看可见 assistant，用于判定可恢复内容
                    let visibleStatus = String.fromDatabaseValue(row["ast_visible"])
                    let target: String
                    if visibleStatus == nil {
                        if anyStatus == nil {
                            continue  // 无 assistant 行：可能仍在生成中，按消息级规则处理
                        }
                        target = "failed"  // B6：assistant 行存在但全部软删，无可见内容可恢复
                    } else {
                        switch visibleStatus {
                        case "canceled":
                            target = "aborted"   // B2：取消已在消息上落地，组未收尾
                        case "sent":
                            target = "complete"  // B3：assistant 已定稿，组缺收尾
                        case "sending":
                            continue             // 并发生成中，不误伤
                        default:
                            target = "failed"    // B4/B5：failed / draft 等异常状态
                        }
                    }
                    try db.execute(
                        sql: "UPDATE message_groups SET status = ?, closed_at = ? WHERE id = ? AND status = 'open'",
                        arguments: [target, now, groupID]
                    )
                    guard db.changesCount == 1 else { continue }
                    closed += 1
                    // B5：没有可见 assistant 时，残留的 user sending 一并转 failed，保证组合合法
                    if visibleStatus == nil {
                        try db.execute(
                            sql: """
                            UPDATE messages SET status = 'failed'
                            WHERE group_id = ? AND status = 'sending'
                            """,
                            arguments: [groupID]
                        )
                    }
                }

                return StaleTurnRepairResult(repairedMessages: repaired, closedGroups: closed)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}

/// 定稿事务仓储：事务 B 与补偿事务 C 的唯一拥有者。
///
/// 事务 B 的原子边界（4.2.5）：
/// ① assistant 定稿 → ② `reply_to_id` → ③ 引用批量写 → ④ 组状态 → ⑤ `closed_at`
/// 任一步抛错，GRDB 的整体写事务回滚，绝不留下"部分引用"或"已 sent 但组仍 open"。
public struct GRDBMessageTurnRepository: MessageTurnRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func finalizeTurn(_ request: FinalizeTurnRequest) async throws {
        do {
            try await database.write { db in
                // ① assistant 定稿：只允许从 sending 出发，避免重复定稿
                try db.execute(
                    sql: """
                    UPDATE messages SET text = ?, status = ?, sent_at = ?
                    WHERE id = ? AND status = 'sending'
                    """,
                    arguments: [
                        request.text,
                        request.assistantStatus.rawValue,
                        request.sentAt,
                        request.assistantMessageID
                    ]
                )
                guard db.changesCount == 1 else {
                    // 影响 0 行：助理行不存在或不是 sending → 整个事务回滚
                    throw ChatOrchestrationError.assistantMessageMissing
                }

                guard let conversationID = try String.fetchOne(
                    db,
                    sql: "SELECT conversation_id FROM message_groups WHERE id = ?",
                    arguments: [request.groupID]
                ) else {
                    throw DFError.database("消息组不存在：\(request.groupID)")
                }

                // ①.4 首条气泡正文入全文索引（定稿文本才是可检索文本）
                try MessageIndexer.index(
                    db: db,
                    messageID: request.assistantMessageID,
                    conversationID: conversationID,
                    text: request.text
                )

                // ①.5 多气泡：后续气泡在同一事务内追加，任一失败整体回滚。
                //      seq 从当前组内最大值继续递增，绝不与首条或历史消息重号。
                if !request.additionalBubbles.isEmpty {
                    var seq = try GRDBMessageGroupRepository.maxSeqValue(db, groupID: request.groupID) ?? 0
                    for bubble in request.additionalBubbles {
                        let trimmed = bubble.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        seq += 1
                        let message = Message(
                            conversationID: conversationID,
                            role: .assistant,
                            text: trimmed,
                            status: request.assistantStatus,
                            origin: .reply,
                            createdAt: request.sentAt ?? Clock.nowMillis(),
                            sentAt: request.sentAt,
                            groupID: request.groupID,
                            seqInGroup: seq
                        )
                        try message.insert(db)
                        try MessageIndexer.index(
                            db: db,
                            messageID: message.id,
                            conversationID: conversationID,
                            text: trimmed
                        )
                    }
                }

                // ② 唯一主引用：仅当原值为空时写入，不覆盖已有引用
                if let replyToID = request.replyToID {
                    try db.execute(
                        sql: "UPDATE messages SET reply_to_id = ? WHERE id = ? AND reply_to_id IS NULL",
                        arguments: [replyToID, request.assistantMessageID]
                    )
                }

                // ③ 引用明细批量写（复合主键冲突时幂等忽略）
                for reference in request.references {
                    try reference.insert(db, onConflict: .ignore)
                }

                // ④⑤ 组状态 + closed_at：仅 open 组可定稿
                try db.execute(
                    sql: """
                    UPDATE message_groups SET status = ?, closed_at = ?
                    WHERE id = ? AND status = 'open'
                    """,
                    arguments: [request.groupStatus.rawValue, request.closedAt, request.groupID]
                )
                guard db.changesCount == 1 else {
                    throw DFError.database("消息组不在 open 状态，无法定稿：\(request.groupID)")
                }

                // 组合合法性自检（事务内，失败即回滚）
                guard GroupPlanner.isValidCombination(
                    group: request.groupStatus,
                    assistant: request.assistantStatus
                ) else {
                    throw DFError.database(
                        "组状态与 assistant 状态组合不合法：\(request.groupStatus.rawValue) + \(request.assistantStatus.rawValue)"
                    )
                }
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func failTurn(groupID: String, assistantMessageID: String, text: String?, closedAt: Int64) async throws {
        do {
            try await database.write { db in
                // 补偿：已 sent 的记录不回退，只处理未定稿的行
                try db.execute(
                    sql: """
                    UPDATE messages SET status = 'failed', text = COALESCE(?, text)
                    WHERE id = ? AND status <> 'sent'
                    """,
                    arguments: [text, assistantMessageID]
                )
                // 仅 open 组跟随；终态组保持不变
                try db.execute(
                    sql: """
                    UPDATE message_groups SET status = 'failed', closed_at = ?
                    WHERE id = ? AND status = 'open'
                    """,
                    arguments: [closedAt, groupID]
                )
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}
