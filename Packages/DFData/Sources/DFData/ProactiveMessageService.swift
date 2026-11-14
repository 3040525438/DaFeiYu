import Foundation
import GRDB
import DFCore

/// 主动消息治理（W7-6 / D50）：记录、发送留痕、收藏、不感兴趣、减少类似、删除与触发原因。
///
/// 边界：
/// - 删除是**软删除**（`status = 'deleted'`），保留触发原因与反馈，便于追溯与抑制同类；
/// - "不感兴趣"与"减少类似"写 `feedback`，供意图生成侧查询 `suppressedTriggerKinds`；
/// - 未表态（`none`）不得被推断为喜欢或不喜欢；
/// - 发送成功必须回填 `sent_at`，它是每日上限与最小间隔的唯一事实源。
public final class ProactiveMessageService: @unchecked Sendable {
    /// "不感兴趣"在该窗口内持续抑制同类主动消息（默认 30 天）
    public static let suppressionWindowMillis: Int64 = 30 * 24 * 60 * 60 * 1000

    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    // MARK: - 记录

    @discardableResult
    public func record(
        text: String,
        triggerKind: String,
        plannedAt: Int64,
        triggerRef: String? = nil,
        notifyLevel: NotificationLevel = .brief,
        dedupeKey: String? = nil,
        expiresAt: Int64? = nil,
        priority: Int = 3,
        intentID: String? = nil,
        characterID: String? = nil,
        moodCode: String? = nil
    ) async throws -> ProactiveMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProactiveMessageError.emptyText
        }
        return try await database.write { db in
            let id = UUID().uuidString
            try db.execute(
                sql: """
                INSERT INTO proactive_messages
                    (id, intent_id, planned_at, text, is_voice, status, priority, expires_at,
                     dedupe_key, notify_level, character_id, mood_code, trigger_kind, trigger_ref,
                     feedback, is_favorite)
                VALUES (?, ?, ?, ?, 0, 'planned', ?, ?, ?, ?, ?, ?, ?, ?, 'none', 0)
                """,
                arguments: [
                    id, intentID, plannedAt, trimmed, max(1, priority), expiresAt,
                    dedupeKey, notifyLevel.rawValue, characterID, moodCode, triggerKind, triggerRef
                ]
            )
            return try self.load(db, id: id)
        }
    }

    /// 标记已发送：写入 `sent_at` 与关联消息 ID。只允许从 planned 进入 sent。
    @discardableResult
    public func markSent(id: String, messageID: String) async throws -> ProactiveMessage {
        try await database.write { db in
            let status = try self.currentStatus(db, id: id)
            guard status == .planned else {
                throw ProactiveMessageError.invalidState("当前为 \(status.rawValue)，只有 planned 可发送")
            }
            let at = self.now()
            try db.execute(
                sql: """
                UPDATE proactive_messages
                   SET status = 'sent', sent_at = ?, message_id = ?, resolved_at = ?
                 WHERE id = ?
                """,
                arguments: [at, messageID, at, id]
            )
            return try self.load(db, id: id)
        }
    }

    /// 标记被闸门拦截：保留原因，便于"为什么没有收到"的排查。
    public func markSuppressed(id: String, reason: String) async throws {
        try await database.write { db in
            let status = try self.currentStatus(db, id: id)
            guard status == .planned else {
                throw ProactiveMessageError.invalidState("当前为 \(status.rawValue)，只有 planned 可抑制")
            }
            try db.execute(
                sql: """
                UPDATE proactive_messages
                   SET status = 'suppressed', suppress_reason = ?, resolved_at = ?
                 WHERE id = ?
                """,
                arguments: [reason, self.now(), id]
            )
        }
    }

    // MARK: - 用户反馈

    @discardableResult
    public func setFavorite(id: String, favorite: Bool) async throws -> ProactiveMessage {
        try await database.write { db in
            _ = try self.currentStatus(db, id: id)
            try db.execute(
                sql: "UPDATE proactive_messages SET is_favorite = ? WHERE id = ?",
                arguments: [favorite ? 1 : 0, id]
            )
            return try self.load(db, id: id)
        }
    }

    @discardableResult
    public func setFeedback(id: String, feedback: ProactiveFeedback) async throws -> ProactiveMessage {
        try await database.write { db in
            _ = try self.currentStatus(db, id: id)
            try db.execute(
                sql: """
                UPDATE proactive_messages
                   SET feedback = ?, feedback_at = ?
                 WHERE id = ?
                """,
                arguments: [feedback.rawValue, self.now(), id]
            )
            return try self.load(db, id: id)
        }
    }

    /// 软删除：只改状态，不物理删除，重复删除幂等。
    public func delete(id: String) async throws {
        try await database.write { db in
            let status = try self.currentStatus(db, id: id)
            if status == .deleted { return }
            try db.execute(
                sql: "UPDATE proactive_messages SET status = 'deleted', resolved_at = ? WHERE id = ?",
                arguments: [self.now(), id]
            )
        }
    }

    // MARK: - 查询

    public func list(includeDeleted: Bool = false, limit: Int = 200) async throws -> [ProactiveMessage] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM proactive_messages
                 WHERE (? = 1 OR status <> 'deleted')
                 ORDER BY planned_at DESC, id DESC
                 LIMIT ?
                """,
                arguments: [includeDeleted ? 1 : 0, max(1, limit)]
            )
            return rows.map(Self.decode)
        }
    }

    public func favorites(limit: Int = 100) async throws -> [ProactiveMessage] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM proactive_messages
                 WHERE is_favorite = 1 AND status <> 'deleted'
                 ORDER BY planned_at DESC, id DESC
                 LIMIT ?
                """,
                arguments: [max(1, limit)]
            )
            return rows.map(Self.decode)
        }
    }

    /// 触发原因：类型、引用、意图理由与证据；`trigger_ref` 为 `memory:<id>` 时解析出关联记忆。
    public func explain(id: String) async throws -> ProactiveMessageExplanation {
        try await database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM proactive_messages WHERE id = ?",
                arguments: [id]
            ) else {
                throw ProactiveMessageError.notFound(id)
            }
            let message = Self.decode(row)
            var reason: String?
            var evidence: String?
            if let intentID = message.intentID,
               let intent = try Row.fetchOne(
                   db,
                   sql: "SELECT reason, evidence_json FROM conversation_intents WHERE id = ?",
                   arguments: [intentID]
               ) {
                reason = try? intent.decode(String.self, forColumn: "reason")
                evidence = try? intent.decode(String.self, forColumn: "evidence_json")
            }
            return ProactiveMessageExplanation(
                messageID: message.id,
                triggerKind: message.triggerKind,
                triggerRef: message.triggerRef,
                intentReason: reason,
                evidenceJSON: evidence,
                relatedMemoryID: ProactiveTriggerRef.memoryID(from: message.triggerRef)
            )
        }
    }

    /// 被用户明确"不感兴趣"的主动消息类型：意图生成侧据此跳过同类。
    public func suppressedTriggerKinds() async throws -> Set<String> {
        try await database.dbQueue.read { db in
            let since = self.now() - Self.suppressionWindowMillis
            let kinds = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT trigger_kind FROM proactive_messages
                 WHERE feedback = 'not_interested'
                   AND trigger_kind IS NOT NULL
                   AND coalesce(feedback_at, planned_at) >= ?
                """,
                arguments: [since]
            )
            return Set(kinds)
        }
    }

    // MARK: - 内部

    private func currentStatus(_ db: Database, id: String) throws -> ProactiveMessageStatus {
        guard let raw = try String.fetchOne(
            db,
            sql: "SELECT status FROM proactive_messages WHERE id = ?",
            arguments: [id]
        ) else {
            throw ProactiveMessageError.notFound(id)
        }
        guard let status = ProactiveMessageStatus(rawValue: raw) else {
            throw ProactiveMessageError.invalidState(raw)
        }
        return status
    }

    private func load(_ db: Database, id: String) throws -> ProactiveMessage {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM proactive_messages WHERE id = ?",
            arguments: [id]
        ) else {
            throw ProactiveMessageError.notFound(id)
        }
        return Self.decode(row)
    }

    private static func decode(_ row: Row) -> ProactiveMessage {
        ProactiveMessage(
            id: (try? row.decode(String.self, forColumn: "id")) ?? "",
            intentID: optionalString(row, "intent_id"),
            plannedAt: (try? row.decode(Int64.self, forColumn: "planned_at")) ?? 0,
            text: (try? row.decode(String.self, forColumn: "text")) ?? "",
            isVoice: ((try? row.decode(Int.self, forColumn: "is_voice")) ?? 0) == 1,
            status: ProactiveMessageStatus(
                rawValue: (try? row.decode(String.self, forColumn: "status")) ?? ""
            ) ?? .planned,
            suppressReason: optionalString(row, "suppress_reason"),
            notificationID: optionalString(row, "notification_id"),
            resolvedAt: optionalInt64(row, "resolved_at"),
            priority: (try? row.decode(Int.self, forColumn: "priority")) ?? 3,
            expiresAt: optionalInt64(row, "expires_at"),
            dedupeKey: optionalString(row, "dedupe_key"),
            messageID: optionalString(row, "message_id"),
            sentAt: optionalInt64(row, "sent_at"),
            characterID: optionalString(row, "character_id"),
            moodCode: optionalString(row, "mood_code"),
            notifyLevel: NotificationLevel(
                rawValue: (try? row.decode(String.self, forColumn: "notify_level")) ?? ""
            ) ?? .brief,
            feedback: ProactiveFeedback(
                rawValue: (try? row.decode(String.self, forColumn: "feedback")) ?? ""
            ) ?? .none,
            feedbackAt: optionalInt64(row, "feedback_at"),
            isFavorite: ((try? row.decode(Int.self, forColumn: "is_favorite")) ?? 0) == 1,
            triggerKind: optionalString(row, "trigger_kind"),
            triggerRef: optionalString(row, "trigger_ref")
        )
    }

    private static func optionalString(_ row: Row, _ column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        return String.fromDatabaseValue(row[column])
    }

    private static func optionalInt64(_ row: Row, _ column: String) -> Int64? {
        guard row.hasColumn(column) else { return nil }
        return Int64.fromDatabaseValue(row[column])
    }
}
