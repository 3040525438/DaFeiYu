import Foundation
import GRDB
import DFCore

/// 自主策略状态：策略本身 + 暂停截止时间。
public struct AutonomyState: Sendable, Equatable {
    public var policy: AutonomyPolicy
    public var pausedUntil: Int64?

    public init(policy: AutonomyPolicy, pausedUntil: Int64?) {
        self.policy = policy
        self.pausedUntil = pausedUntil
    }
}

/// 启动补算计划：漏掉的每日任务 + 因后台中断而未执行的任务。
public struct AutonomyBackfillResult: Sendable, Equatable {
    public var missedKinds: [ProactiveTrigger]
    public var overdueTaskIDs: [String]
    public var createdTaskIDs: [String]
    public var expiredCount: Int
}

/// 发送闸门结论：闸门决定 + 本次留痕 + 应当采用的通知档位。
public struct AutonomyGateResult: Sendable, Equatable {
    public var decision: AutonomyDecision
    public var runID: String
    public var notificationLevel: NotificationLevel
}

/// 自主调度（W7）：策略持久化、五重闸门接线、任务队列、执行留痕与后台补算。
///
/// 边界（D13 / D14 / D15 / D54 / D68）：
/// - 闸门的每一次放行或拦截都写一条 `autonomy_runs`，不静默放过；
/// - 策略以 `settings` 的 JSON 为基线，`autonomy_controls` 的分项开关与暂停覆盖基线；
/// - 任务以 `dedupe_key` 唯一：同一话题同一类型只排一次，重复入队返回既有任务；
/// - 后台不保证及时（D21）：未执行的任务保持 pending，启动时由 `backfill` 补算；
/// - 预算闸门只读调用方传入的"今日已花费"，不在本服务里猜测成本。
public final class AutonomyService: @unchecked Sendable {
    /// settings 中存放策略 JSON 的键
    public static let policyKey = "autonomy.policy"
    /// `autonomy_controls` 中存放全局开关与暂停的行
    public static let globalControlKind = "global"

    private let database: AppDatabase
    private let clock: AutonomyClock

    public init(database: AppDatabase, clock: AutonomyClock = .system) {
        self.database = database
        self.clock = clock
    }

    // MARK: - 策略

    public func state() async throws -> AutonomyState {
        try await database.dbQueue.read { db in
            var policy = try self.loadPolicy(db)
            var pausedUntil: Int64?
            let controls = try Row.fetchAll(
                db,
                sql: "SELECT item_kind, enabled, paused_until FROM autonomy_controls"
            )
            for row in controls {
                let kind = (try? row.decode(String.self, forColumn: "item_kind")) ?? ""
                let enabled = ((try? row.decode(Int.self, forColumn: "enabled")) ?? 0) == 1
                if kind == Self.globalControlKind {
                    policy.enabled = enabled
                    pausedUntil = Self.optionalInt64(row, "paused_until")
                    continue
                }
                guard let trigger = Self.controlKindMapping.first(where: { $0.value == kind })?.key else {
                    continue
                }
                Self.setAllow(&policy, trigger: trigger, enabled: enabled)
            }
            return AutonomyState(policy: policy.normalized(), pausedUntil: pausedUntil)
        }
    }

    public func savePolicy(_ policy: AutonomyPolicy) async throws {
        let normalized = policy.normalized()
        try await database.write { db in
            let data = try JSONEncoder().encode(normalized)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try Self.writeSetting(db, key: Self.policyKey, value: json)

            let at = self.clock.now()
            for (trigger, kind) in Self.controlKindMapping {
                let enabled = normalized.allows(trigger) ? 1 : 0
                try db.execute(
                    sql: """
                    INSERT INTO autonomy_controls
                        (id, item_kind, level, enabled, paused_until, updated_by, updated_at)
                    VALUES (?, ?, ?, ?, NULL, 'user', ?)
                    ON CONFLICT(item_kind) DO UPDATE SET
                        level = excluded.level, enabled = excluded.enabled,
                        updated_by = 'user', updated_at = excluded.updated_at
                    """,
                    arguments: [UUID().uuidString, kind, enabled == 1 ? "on" : "off", enabled, at]
                )
            }
            // 总开关落在 global 行；不覆盖已有的暂停时间
            try db.execute(
                sql: """
                INSERT INTO autonomy_controls
                    (id, item_kind, level, enabled, paused_until, updated_by, updated_at)
                VALUES (?, ?, ?, ?, NULL, 'user', ?)
                ON CONFLICT(item_kind) DO UPDATE SET
                    level = excluded.level, enabled = excluded.enabled,
                    updated_by = 'user', updated_at = excluded.updated_at
                """,
                arguments: [
                    UUID().uuidString,
                    Self.globalControlKind,
                    normalized.enabled ? "on" : "off",
                    normalized.enabled ? 1 : 0,
                    at
                ]
            )
        }
    }

    /// 暂停自主行为到指定时间；传 nil 等于立即恢复。
    public func pause(until millis: Int64?) async throws {
        let now = clock.now()
        if let millis, millis <= now {
            throw AutonomyError.invalidPayload("暂停截止时间必须晚于当前时间")
        }
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO autonomy_controls
                    (id, item_kind, level, enabled, paused_until, updated_by, updated_at)
                VALUES (?, ?, 'on', 1, ?, 'user', ?)
                ON CONFLICT(item_kind) DO UPDATE SET
                    paused_until = excluded.paused_until,
                    updated_by = 'user', updated_at = excluded.updated_at
                """,
                arguments: [UUID().uuidString, Self.globalControlKind, millis, now]
            )
        }
    }

    public func resume() async throws {
        try await pause(until: nil)
    }

    /// 恢复默认策略：清空分项覆盖并重写基线。
    public func resetToDefault() async throws {
        try await savePolicy(.default)
    }

    // MARK: - 任务队列

    @discardableResult
    public func enqueue(
        kind: ProactiveTrigger,
        conversationID: String? = nil,
        topicID: String? = nil,
        dedupeKey: String,
        priority: Int = 3,
        scheduledAt: Int64,
        expiresAt: Int64? = nil,
        maxAttempts: Int = 3,
        payloadJSON: String = "{}"
    ) async throws -> AutonomyTask {
        let trimmedKey = dedupeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AutonomyError.invalidPayload("dedupe_key 不能为空")
        }
        guard !kind.rawValue.isEmpty else {
            throw AutonomyError.invalidPayload("任务类型不能为空")
        }
        guard Self.isJSONObject(payloadJSON) else {
            throw AutonomyError.invalidPayload("payload 必须是 JSON 对象")
        }
        return try await database.write { db in
            let at = self.clock.now()
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO autonomy_tasks
                    (id, kind, conversation_id, topic_id, dedupe_key, status, priority,
                     scheduled_at, expires_at, attempts, max_attempts, last_attempt_at,
                     payload_json, result_json, error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, 0, ?, NULL, ?, NULL, NULL, ?, ?)
                """,
                arguments: [
                    UUID().uuidString, kind.rawValue, conversationID, topicID, trimmedKey,
                    max(1, priority), scheduledAt, expiresAt, max(1, maxAttempts),
                    payloadJSON, at, at
                ]
            )
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM autonomy_tasks WHERE dedupe_key = ?",
                arguments: [trimmedKey]
            ) else {
                throw AutonomyError.taskNotFound(trimmedKey)
            }
            return Self.decodeTask(row)
        }
    }

    /// 到期且未过期的 pending 任务，按优先级与时计划排序。
    public func dueTasks(limit: Int = 20) async throws -> [AutonomyTask] {
        try await database.dbQueue.read { db in
            let now = self.clock.now()
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM autonomy_tasks
                 WHERE status = 'pending' AND scheduled_at <= ?
                   AND (expires_at IS NULL OR expires_at > ?)
                 ORDER BY priority ASC, scheduled_at ASC
                 LIMIT ?
                """,
                arguments: [now, now, max(1, limit)]
            )
            return rows.map(Self.decodeTask)
        }
    }

    /// 认领任务：pending → running 且 attempts + 1；重试用尽时标记 failed 并返回 nil。
    @discardableResult
    public func claim(taskID: String) async throws -> AutonomyTask? {
        try await database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM autonomy_tasks WHERE id = ?",
                arguments: [taskID]
            ) else {
                throw AutonomyError.taskNotFound(taskID)
            }
            let task = Self.decodeTask(row)
            guard task.status == .pending else { return nil }
            let now = self.clock.now()
            guard task.attempts < task.maxAttempts else {
                try db.execute(
                    sql: """
                    UPDATE autonomy_tasks
                       SET status = 'failed', error = ?, updated_at = ?
                     WHERE id = ?
                    """,
                    arguments: ["超过最大重试次数", now, taskID]
                )
                return nil
            }
            try db.execute(
                sql: """
                UPDATE autonomy_tasks
                   SET status = 'running', attempts = attempts + 1,
                       last_attempt_at = ?, updated_at = ?
                 WHERE id = ? AND status = 'pending'
                """,
                arguments: [now, now, taskID]
            )
            var claimed = task
            claimed.status = .running
            claimed.attempts = task.attempts + 1
            claimed.lastAttemptAt = now
            claimed.updatedAt = now
            return claimed
        }
    }

    /// 结束任务：只接受 done / skipped / failed；从 running 之外的终态重复调用直接报错。
    /// 结束时自动写一条 `autonomy_runs`，保证"执行记录"不依赖调用方记得补写。
    public func finish(
        taskID: String,
        status: AutonomyTaskStatus,
        resultJSON: String? = nil,
        error: String? = nil
    ) async throws {
        guard status == .done || status == .skipped || status == .failed else {
            throw AutonomyError.invalidStatus(status.rawValue)
        }
        try await database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT status, kind FROM autonomy_tasks WHERE id = ?",
                arguments: [taskID]
            ) else {
                throw AutonomyError.taskNotFound(taskID)
            }
            let current = (try? row.decode(String.self, forColumn: "status")) ?? ""
            guard current == AutonomyTaskStatus.running.rawValue else {
                throw AutonomyError.taskNotPending(current)
            }
            let now = self.clock.now()
            try db.execute(
                sql: """
                UPDATE autonomy_tasks
                   SET status = ?, result_json = ?, error = ?, updated_at = ?
                 WHERE id = ?
                """,
                arguments: [status.rawValue, resultJSON, error, now, taskID]
            )
            let runStatus: AutonomyRunStatus
            switch status {
            case .done: runStatus = .done
            case .skipped: runStatus = .skipped
            default: runStatus = .failed
            }
            let runDecision: String? = status == .done ? "allow" : nil
            try db.execute(
                sql: """
                INSERT INTO autonomy_runs
                    (id, task_id, kind, trigger, status, decision, block_reason,
                     model_config_id, started_at, finished_at, duration_ms, detail_json, error)
                VALUES (?, ?, ?, 'foreground', ?, ?, NULL, NULL, ?, ?, NULL, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    taskID,
                    (try? row.decode(String.self, forColumn: "kind")) ?? "",
                    runStatus.rawValue,
                    runDecision,
                    now,
                    now,
                    resultJSON ?? "{}",
                    error
                ]
            )
        }
    }

    /// 把已过期的任务统一标记为 expired（不删除，保留可追溯记录）。
    @discardableResult
    public func expireStale() async throws -> Int {
        try await database.write { db in
            let now = self.clock.now()
            try db.execute(
                sql: """
                UPDATE autonomy_tasks
                   SET status = 'expired', error = '已过期', updated_at = ?
                 WHERE status = 'pending' AND expires_at IS NOT NULL AND expires_at <= ?
                """,
                arguments: [now, now]
            )
            return db.changesCount
        }
    }

    // MARK: - 后台补算

    /// 启动补算：过期任务作废；漏掉的每日任务补建为"立即执行"任务；返回未执行完的积压任务。
    public func backfill() async throws -> AutonomyBackfillResult {
        let expired = try await expireStale()
        let now = clock.now()
        let dayStart = clock.dayStart(now)

        let lastSuccess = try await lastSuccessTimes()
        let missed = AutonomyBackfill.missedDailyKinds(lastSuccessAt: lastSuccess, dayStartMillis: dayStart)

        var created: [String] = []
        for kind in missed {
            let task = try await enqueue(
                kind: kind,
                dedupeKey: "daily:\(kind.rawValue):\(dayStart)",
                priority: 2,
                scheduledAt: now,
                payloadJSON: "{\"reason\":\"launch_backfill\"}"
            )
            created.append(task.id)
        }

        let overdue = try await dueTasks(limit: 50)
        try await recordRun(
            taskID: nil,
            kind: "backfill",
            trigger: "launch_backfill",
            status: .done,
            decision: "allow",
            blockReason: nil,
            detailJSON: "{\"expired\":\(expired),\"missed\":\(missed.count),\"overdue\":\(overdue.count)}"
        )

        return AutonomyBackfillResult(
            missedKinds: missed,
            overdueTaskIDs: overdue.map(\.id),
            createdTaskIDs: created,
            expiredCount: expired
        )
    }

    // MARK: - 发送闸门

    /// 评估一次主动行为是否放行，并把结论写入 `autonomy_runs`。
    /// - Parameters:
    ///   - todaySpentYuan: 今日已花费（由模型成本记账方传入，未接入时为 0）
    ///   - notificationsAuthorized: 用户是否已授权通知
    public func evaluateSend(
        trigger: ProactiveTrigger,
        todaySpentYuan: Double = 0,
        notificationsAuthorized: Bool = true,
        taskID: String? = nil,
        runTrigger: String = "foreground"
    ) async throws -> AutonomyGateResult {
        let state = try await state()
        let now = clock.now()
        let dayStart = clock.dayStart(now)
        let minute = clock.minuteOfDay(now)

        let stats = try await database.dbQueue.read { db -> (Int64?, Int) in
            let last = try Int64.fetchOne(
                db,
                sql: """
                SELECT max(sent_at) FROM proactive_messages
                 WHERE sent_at IS NOT NULL AND sent_at >= ?
                """,
                arguments: [dayStart]
            )
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM proactive_messages
                 WHERE status = 'sent' AND sent_at IS NOT NULL AND sent_at >= ?
                """,
                arguments: [dayStart]
            ) ?? 0
            return (last, count)
        }

        let decision = AutonomyGate.evaluate(
            policy: state.policy,
            trigger: trigger,
            nowMillis: now,
            nowMinuteOfDay: minute,
            lastSentAt: stats.0,
            todaySentCount: stats.1,
            pausedUntil: state.pausedUntil,
            todaySpentYuan: todaySpentYuan,
            notificationsAuthorized: notificationsAuthorized
        )

        let runID = try await recordRun(
            taskID: taskID,
            kind: trigger.rawValue,
            trigger: runTrigger,
            status: decision.allowed ? .allowed : .blocked,
            decision: decision.allowed ? "allow" : "block",
            blockReason: decision.reason,
            detailJSON: "{\"today_sent\":\(stats.1),\"spent_yuan\":\(todaySpentYuan)}"
        )

        return AutonomyGateResult(
            decision: decision,
            runID: runID,
            notificationLevel: state.policy.notificationLevel
        )
    }

    // MARK: - 执行记录

    @discardableResult
    public func recordRun(
        taskID: String?,
        kind: String,
        trigger: String,
        status: AutonomyRunStatus,
        decision: String?,
        blockReason: String?,
        detailJSON: String = "{}",
        error: String? = nil,
        modelConfigID: String? = nil
    ) async throws -> String {
        try await database.write { db in
            let now = self.clock.now()
            let id = UUID().uuidString
            let finished = status == .running ? nil : now
            try db.execute(
                sql: """
                INSERT INTO autonomy_runs
                    (id, task_id, kind, trigger, status, decision, block_reason,
                     model_config_id, started_at, finished_at, duration_ms, detail_json, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                """,
                arguments: [
                    id, taskID, kind, trigger, status.rawValue, decision, blockReason,
                    modelConfigID, now, finished, detailJSON, error
                ]
            )
            return id
        }
    }

    public func runs(limit: Int = 100) async throws -> [AutonomyRun] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM autonomy_runs ORDER BY started_at DESC, id DESC LIMIT ?
                """,
                arguments: [max(1, limit)]
            )
            return rows.map(Self.decodeRun)
        }
    }

    // MARK: - 内部

    private static let controlKindMapping: [(key: ProactiveTrigger, value: String)] = [
        (.message, "proactive_message"),
        (.newConversation, "new_conversation"),
        (.memoryConsolidation, "memory_consolidation"),
        (.selfReflection, "self_reflection"),
        (.suggestion, "suggestion")
    ]

    private static func setAllow(_ policy: inout AutonomyPolicy, trigger: ProactiveTrigger, enabled: Bool) {
        switch trigger {
        case .message: policy.allowProactiveMessage = enabled
        case .newConversation: policy.allowNewConversation = enabled
        case .memoryConsolidation: policy.allowMemoryConsolidation = enabled
        case .selfReflection: policy.allowSelfReflection = enabled
        case .suggestion: policy.allowSuggestion = enabled
        }
    }

    private func loadPolicy(_ db: Database) throws -> AutonomyPolicy {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT value FROM settings WHERE key = ?",
            arguments: [Self.policyKey]
        ), let data = json.data(using: .utf8),
              let policy = try? JSONDecoder().decode(AutonomyPolicy.self, from: data) else {
            // 配置缺失或损坏时退回保守默认值，不因坏配置阻断启动
            return .default
        }
        return policy
    }

    private static func writeSetting(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO settings (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    private func lastSuccessTimes() async throws -> [ProactiveTrigger: Int64] {
        try await database.dbQueue.read { db in
            var result: [ProactiveTrigger: Int64] = [:]
            for kind in AutonomyBackfill.dailyKinds {
                if let value = try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT max(coalesce(finished_at, started_at)) FROM autonomy_runs
                     WHERE kind = ? AND status = 'done'
                    """,
                    arguments: [kind.rawValue]
                ) {
                    result[kind] = value
                }
            }
            return result
        }
    }

    private static func isJSONObject(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return object is [String: Any]
    }

    // MARK: 解码

    private static func decodeTask(_ row: Row) -> AutonomyTask {
        AutonomyTask(
            id: (try? row.decode(String.self, forColumn: "id")) ?? "",
            kind: (try? row.decode(String.self, forColumn: "kind")) ?? "",
            conversationID: optionalString(row, "conversation_id"),
            topicID: optionalString(row, "topic_id"),
            dedupeKey: (try? row.decode(String.self, forColumn: "dedupe_key")) ?? "",
            status: AutonomyTaskStatus(
                rawValue: (try? row.decode(String.self, forColumn: "status")) ?? ""
            ) ?? .pending,
            priority: (try? row.decode(Int.self, forColumn: "priority")) ?? 3,
            scheduledAt: (try? row.decode(Int64.self, forColumn: "scheduled_at")) ?? 0,
            expiresAt: optionalInt64(row, "expires_at"),
            attempts: (try? row.decode(Int.self, forColumn: "attempts")) ?? 0,
            maxAttempts: (try? row.decode(Int.self, forColumn: "max_attempts")) ?? 3,
            lastAttemptAt: optionalInt64(row, "last_attempt_at"),
            payloadJSON: (try? row.decode(String.self, forColumn: "payload_json")) ?? "{}",
            resultJSON: optionalString(row, "result_json"),
            error: optionalString(row, "error"),
            createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0,
            updatedAt: (try? row.decode(Int64.self, forColumn: "updated_at")) ?? 0
        )
    }

    private static func decodeRun(_ row: Row) -> AutonomyRun {
        AutonomyRun(
            id: (try? row.decode(String.self, forColumn: "id")) ?? "",
            taskID: optionalString(row, "task_id"),
            kind: (try? row.decode(String.self, forColumn: "kind")) ?? "",
            trigger: (try? row.decode(String.self, forColumn: "trigger")) ?? "foreground",
            status: AutonomyRunStatus(
                rawValue: (try? row.decode(String.self, forColumn: "status")) ?? ""
            ) ?? .running,
            decision: optionalString(row, "decision"),
            blockReason: optionalString(row, "block_reason"),
            modelConfigID: optionalString(row, "model_config_id"),
            startedAt: (try? row.decode(Int64.self, forColumn: "started_at")) ?? 0,
            finishedAt: optionalInt64(row, "finished_at"),
            durationMs: optionalInt64(row, "duration_ms"),
            detailJSON: (try? row.decode(String.self, forColumn: "detail_json")) ?? "{}",
            error: optionalString(row, "error")
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
