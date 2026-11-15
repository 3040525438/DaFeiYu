import Foundation
import GRDB
import DFCore

/// 一条成本记录（审计用）。
public struct CostRecord: Sendable, Equatable {
    public var id: String
    public var dayKey: String
    public var scope: BudgetScope
    public var refID: String?
    public var provider: String
    public var modelID: String
    /// reserved / settled / failed / cancelled
    public var status: String
    public var costKind: CostKind
    /// 无法计量时为 nil（绝不写 0 冒充）
    public var costYuan: Double?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var currency: String
    public var note: String?
    public var createdAt: Int64
    public var settledAt: Int64?
}

public enum BudgetError: Error, Equatable, CustomStringConvertible {
    case blocked(reason: String)
    case reservationNotFound(String)
    case alreadyFinished(String)

    public var description: String {
        switch self {
        case .blocked(let reason):
            return reason
        case .reservationNotFound(let id):
            return "找不到预算预占记录：\(id)"
        case .alreadyFinished(let id):
            return "预算预占已结束，不能重复结算：\(id)"
        }
    }
}

/// D10：预算与成本服务。
///
/// 关键保证：
/// - **并发安全**：`reserve` 在单个写事务里"读当日花费 + 判定 + 插入预占"，GRDB 写事务串行化，
///   并发调用不可能同时绕过上限；
/// - **未知不为 0**：无用量/无单价的记录 `cost_yuan` 为 NULL，按 `unknownReserveYuan` 保守计入判定；
/// - **跨日重置**：所有聚合都按本地日期 `day_key` 过滤，跨日自动从 0 起算；
/// - **审计**：每次调用都留一行 `cost_ledger`，结算/失败都记录状态与口径。
public final class BudgetService: @unchecked Sendable {
    public enum Key {
        public static let dailyYuan = "budget.daily.yuan"
        public static let perCallYuan = "budget.per_call.yuan"
        public static let autonomyDailyYuan = "budget.autonomy_daily.yuan"
        public static let unknownReserveYuan = "budget.unknown_reserve.yuan"
        public static let pricingPrefix = "budget.pricing."
    }

    private let database: AppDatabase
    private let settings: any SettingsRepository
    private let now: @Sendable () -> Int64
    private let timeZone: TimeZone
    private let fileDateFormatter: DateFormatter

    public init(
        database: AppDatabase,
        settings: any SettingsRepository,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.database = database
        self.settings = settings
        self.timeZone = timeZone
        self.now = now

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.fileDateFormatter = formatter
    }

    // MARK: - 日期

    /// 本地日期键（yyyy-MM-dd），用于跨日重置。
    public func dayKey(for millis: Int64? = nil) -> String {
        let value = millis ?? now()
        return fileDateFormatter.string(
            from: Date(timeIntervalSince1970: Double(value) / 1000)
        )
    }

    public func todayKey() -> String {
        dayKey()
    }

    // MARK: - 配置

    public func limits() async throws -> BudgetLimits {
        let daily = try await doubleValue(Key.dailyYuan)
        let perCall = try await doubleValue(Key.perCallYuan)
        let autonomy = try await doubleValue(Key.autonomyDailyYuan)
        let reserve = try await doubleValue(Key.unknownReserveYuan) ?? 0.02
        return BudgetLimits(
            dailyYuan: daily,
            perCallYuan: perCall,
            autonomyDailyYuan: autonomy,
            unknownReserveYuan: reserve
        ).normalized()
    }

    public func saveLimits(_ limits: BudgetLimits) async throws {
        let value = limits.normalized()
        try await saveOptionalDouble(value.dailyYuan, for: Key.dailyYuan)
        try await saveOptionalDouble(value.perCallYuan, for: Key.perCallYuan)
        try await saveOptionalDouble(value.autonomyDailyYuan, for: Key.autonomyDailyYuan)
        try await settings.set(String(value.unknownReserveYuan), for: Key.unknownReserveYuan)
    }

    public func pricing(modelID: String) async throws -> ModelPricing? {
        guard let raw = try await settings.string(for: Key.pricingPrefix + modelID),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ModelPricing.self, from: data)
    }

    public func savePricing(_ pricing: ModelPricing, modelID: String) async throws {
        let data = try JSONEncoder().encode(pricing)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await settings.set(text, for: Key.pricingPrefix + modelID)
    }

    public func clearPricing(modelID: String) async throws {
        try await settings.set("", for: Key.pricingPrefix + modelID)
    }

    // MARK: - 快照

    public func snapshot(dayKey: String? = nil) async throws -> BudgetSpend {
        let key = dayKey ?? self.dayKey()
        return try await database.dbQueue.read { db in
            try Self.aggregate(db, dayKey: key)
        }
    }

    public func records(dayKey: String? = nil, limit: Int = 50) async throws -> [CostRecord] {
        let key = dayKey ?? self.dayKey()
        return try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM cost_ledger
                 WHERE day_key = ?
                 ORDER BY created_at DESC
                 LIMIT ?
                """,
                arguments: [key, max(1, limit)]
            )
            return rows.map { Self.decode($0) }
        }
    }

    // MARK: - 预占（并发安全）

    /// 调用前预占预算；预算不足抛 `BudgetError.blocked`，不会留下脏记录。
    /// - Parameter estimatedYuan: 本次调用的预估花费；未知单价时传 0，结算时会标为 unavailable。
    @discardableResult
    public func reserve(
        scope: BudgetScope,
        estimatedYuan: Double,
        provider: String,
        modelID: String,
        refID: String? = nil,
        limits: BudgetLimits? = nil
    ) async throws -> String {
        let baseLimits: BudgetLimits
        if let limits {
            baseLimits = limits
        } else {
            baseLimits = try await self.limits()
        }
        let resolvedLimits = baseLimits.normalized()
        let key = dayKey()
        let timestamp = now()
        let id = UUID().uuidString

        return try await database.write { db in
            // 同一写事务内完成"读 + 判定 + 写"，并发调用被 SQLite 串行化，无法互相绕过上限
            let spend = try Self.aggregate(db, dayKey: key)
            let decision = BudgetGuard.evaluate(
                limits: resolvedLimits,
                spend: spend,
                scope: scope,
                estimatedNextCallYuan: estimatedYuan
            )
            guard decision.allowed else {
                throw BudgetError.blocked(reason: decision.reason ?? "预算不足")
            }
            try db.execute(
                sql: """
                INSERT INTO cost_ledger
                    (id, day_key, scope, ref_id, provider, model_id, status,
                     cost_kind, cost_yuan, currency, note, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 'reserved', 'estimated', ?, 'CNY', ?, ?)
                """,
                arguments: [
                    id,
                    key,
                    scope.rawValue,
                    refID,
                    provider,
                    modelID,
                    max(0, estimatedYuan),
                    "调用前预占",
                    timestamp
                ]
            )
            return id
        }
    }

    // MARK: - 结算

    /// 结算一次调用：用量与单价齐全 → confirmed；缺一项 → estimated / unavailable。
    @discardableResult
    public func settle(
        reservationID: String,
        usage: Usage?,
        pricing: ModelPricing?,
        fallbackPromptTokens: Int,
        fallbackCompletionTokens: Int,
        modelID: String? = nil,
        note: String? = nil
    ) async throws -> CostRecord {
        let timestamp = now()
        return try await database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cost_ledger WHERE id = ?",
                arguments: [reservationID]
            ) else {
                throw BudgetError.reservationNotFound(reservationID)
            }
            let status = String.fromDatabaseValue(row["status"]) ?? ""
            guard status == "reserved" else {
                throw BudgetError.alreadyFinished(reservationID)
            }

            let promptTokens = usage?.promptTokens ?? max(0, fallbackPromptTokens)
            let completionTokens = usage?.completionTokens ?? max(0, fallbackCompletionTokens)

            let kind: CostKind
            let cost: Double?
            let resolvedNote: String
            if let pricing, pricing.isUsable {
                if let usage {
                    kind = .confirmed
                    cost = pricing.cost(
                        promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens
                    )
                    resolvedNote = note ?? "服务端用量 + 已知单价"
                } else {
                    kind = .estimated
                    cost = pricing.cost(
                        promptTokens: promptTokens,
                        completionTokens: completionTokens
                    )
                    resolvedNote = note ?? "服务端未返回用量，按字符估算 token"
                }
            } else {
                kind = .unavailable
                cost = nil
                resolvedNote = note ?? "缺少单价，无法计量成本"
            }

            try db.execute(
                sql: """
                UPDATE cost_ledger
                   SET status = 'settled',
                       cost_kind = ?,
                       cost_yuan = ?,
                       prompt_tokens = ?,
                       completion_tokens = ?,
                       model_id = COALESCE(?, model_id),
                       note = ?,
                       settled_at = ?
                 WHERE id = ?
                """,
                arguments: [
                    kind.rawValue,
                    cost,
                    promptTokens,
                    completionTokens,
                    modelID,
                    resolvedNote,
                    timestamp,
                    reservationID
                ]
            )
            guard let updated = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cost_ledger WHERE id = ?",
                arguments: [reservationID]
            ) else {
                throw BudgetError.reservationNotFound(reservationID)
            }
            return Self.decode(updated)
        }
    }

    /// 调用失败：保留预占金额（服务端可能已计费），状态记为 failed，便于审计。
    public func fail(reservationID: String, reason: String) async throws {
        let timestamp = now()
        try await database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT status FROM cost_ledger WHERE id = ?",
                arguments: [reservationID]
            ), let status = String.fromDatabaseValue(row["status"]) else {
                throw BudgetError.reservationNotFound(reservationID)
            }
            guard status == "reserved" else { return }
            try db.execute(
                sql: """
                UPDATE cost_ledger
                   SET status = 'failed', note = ?, settled_at = ?
                 WHERE id = ?
                """,
                arguments: ["调用失败（按预占金额保守计入）：" + reason, timestamp, reservationID]
            )
        }
    }

    /// 调用根本没发出（例如取消）：释放预占，不计入花费。
    public func cancel(reservationID: String, reason: String) async throws {
        let timestamp = now()
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE cost_ledger
                   SET status = 'cancelled', note = ?, settled_at = ?
                 WHERE id = ? AND status = 'reserved'
                """,
                arguments: ["调用未发出：" + reason, timestamp, reservationID]
            )
        }
    }

    // MARK: - 内部

    private static func aggregate(_ db: Database, dayKey: String) throws -> BudgetSpend {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                COALESCE(SUM(CASE WHEN cost_kind = 'confirmed' AND status <> 'cancelled'
                                  THEN cost_yuan ELSE 0 END), 0) AS confirmed,
                COALESCE(SUM(CASE WHEN cost_kind = 'estimated' AND status <> 'cancelled'
                                  THEN cost_yuan ELSE 0 END), 0) AS estimated,
                COALESCE(SUM(CASE WHEN cost_kind = 'unavailable' AND status <> 'cancelled'
                                  THEN 1 ELSE 0 END), 0) AS unknown_count,
                COALESCE(SUM(CASE WHEN scope = 'autonomy' AND status <> 'cancelled'
                                   AND cost_kind IN ('confirmed', 'estimated')
                                  THEN cost_yuan ELSE 0 END), 0) AS autonomy_yuan,
                COALESCE(SUM(CASE WHEN scope = 'autonomy' AND status <> 'cancelled'
                                   AND cost_kind = 'unavailable'
                                  THEN 1 ELSE 0 END), 0) AS autonomy_unknown
              FROM cost_ledger
             WHERE day_key = ?
            """,
            arguments: [dayKey]
        )
        return BudgetSpend(
            confirmedYuan: Double.fromDatabaseValue(row?["confirmed"] ?? .null) ?? 0,
            estimatedYuan: Double.fromDatabaseValue(row?["estimated"] ?? .null) ?? 0,
            unknownCount: Int.fromDatabaseValue(row?["unknown_count"] ?? .null) ?? 0,
            autonomyYuan: Double.fromDatabaseValue(row?["autonomy_yuan"] ?? .null) ?? 0,
            autonomyUnknownCount: Int.fromDatabaseValue(row?["autonomy_unknown"] ?? .null) ?? 0
        )
    }

    private static func decode(_ row: Row) -> CostRecord {
        let scope = BudgetScope(
            rawValue: String.fromDatabaseValue(row["scope"]) ?? "chat"
        ) ?? .chat
        let kind = CostKind(
            rawValue: String.fromDatabaseValue(row["cost_kind"]) ?? "unavailable"
        ) ?? .unavailable
        return CostRecord(
            id: String.fromDatabaseValue(row["id"]) ?? "",
            dayKey: String.fromDatabaseValue(row["day_key"]) ?? "",
            scope: scope,
            refID: String.fromDatabaseValue(row["ref_id"]),
            provider: String.fromDatabaseValue(row["provider"]) ?? "",
            modelID: String.fromDatabaseValue(row["model_id"]) ?? "",
            status: String.fromDatabaseValue(row["status"]) ?? "",
            costKind: kind,
            costYuan: Double.fromDatabaseValue(row["cost_yuan"]),
            promptTokens: Int.fromDatabaseValue(row["prompt_tokens"]),
            completionTokens: Int.fromDatabaseValue(row["completion_tokens"]),
            currency: String.fromDatabaseValue(row["currency"]) ?? "CNY",
            note: String.fromDatabaseValue(row["note"]),
            createdAt: Int64.fromDatabaseValue(row["created_at"]) ?? 0,
            settledAt: Int64.fromDatabaseValue(row["settled_at"])
        )
    }

    private func doubleValue(_ key: String) async throws -> Double? {
        guard let raw = try await settings.string(for: key),
              !raw.isEmpty,
              let value = Double(raw) else {
            return nil
        }
        return value
    }

    private func saveOptionalDouble(_ value: Double?, for key: String) async throws {
        if let value {
            try await settings.set(String(value), for: key)
        } else {
            try await settings.set("", for: key)
        }
    }
}
