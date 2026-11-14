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
public struct GRDBMessageGroupRepository: MessageGroupRepository, Sendable {
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
