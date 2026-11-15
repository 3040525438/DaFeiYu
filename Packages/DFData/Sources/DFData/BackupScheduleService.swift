import Foundation
import GRDB
import DFCore

/// 自动备份调度（W9-2 / D09）。只负责"该不该备份、备份哪一类"，
/// 真正的导出与加密交给 `BackupService`（通过注入的 `createBackup` 闭包）。
///
/// 边界：
/// - 每日完整备份以本地 0 点为界，一天最多一次；
/// - 增量备份只在数据指纹变化时触发，且有最小间隔，避免频繁写盘；
/// - 数据指纹是**轻量**的（行数 + 关键时间列最大值），用于判断"有没有变化"，不是内容哈希；
/// - 备份失败不更新任何时间戳，下次唤醒继续尝试。
public final class BackupScheduleService: @unchecked Sendable {
    public static let keyEnabled = "backup.auto.enabled"
    public static let keyLastAutomaticAt = "backup.auto.last_at"
    public static let keyLastIncrementalAt = "backup.auto.last_incremental_at"
    public static let keyFingerprint = "backup.auto.fingerprint"

    public typealias BackupCreator = @Sendable (BackupKind, String) async throws -> BackupManifest

    public struct Outcome: Sendable, Equatable {
        public var action: BackupScheduleAction
        public var reason: String
        public var manifest: BackupManifest?

        public init(action: BackupScheduleAction, reason: String, manifest: BackupManifest?) {
            self.action = action
            self.reason = reason
            self.manifest = manifest
        }
    }

    private let database: AppDatabase
    private let settings: SettingsRepository
    private let createBackup: BackupCreator
    private let clock: AutonomyClock
    private let policy: BackupSchedulePolicy

    public init(
        database: AppDatabase,
        settings: SettingsRepository,
        policy: BackupSchedulePolicy = .default,
        clock: AutonomyClock = .system,
        createBackup: @escaping BackupCreator
    ) {
        self.database = database
        self.settings = settings
        self.policy = policy
        self.clock = clock
        self.createBackup = createBackup
    }

    // MARK: - 开关

    public func isEnabled() async -> Bool {
        let value = try? await settings.string(for: Self.keyEnabled)
        return value != "false"
    }

    public func setEnabled(_ enabled: Bool) async throws {
        try await settings.set(enabled ? "true" : "false", for: Self.keyEnabled)
    }

    // MARK: - 调度

    /// 每次启动与后台唤醒调用；幂等，重复调用不会产生多余备份。
    public func runIfDue() async throws -> Outcome {
        guard await isEnabled() else {
            return Outcome(action: .skip, reason: "自动备份已关闭", manifest: nil)
        }
        guard try await hasData() else {
            return Outcome(action: .skip, reason: "还没有可备份的数据", manifest: nil)
        }

        let now = clock.now()
        let dayStart = clock.dayStart(now)
        let lastAutomatic = await intSetting(Self.keyLastAutomaticAt)
        let lastIncremental = await intSetting(Self.keyLastIncrementalAt)
        let fingerprint = try await currentFingerprint()
        let lastFingerprint = try? await settings.string(for: Self.keyFingerprint)

        let decision = policy.decide(
            nowMillis: now,
            dayStartMillis: dayStart,
            lastAutomaticAt: lastAutomatic,
            lastIncrementalAt: lastIncremental,
            dataChanged: fingerprint != lastFingerprint
        )

        switch decision.action {
        case .skip:
            return Outcome(action: .skip, reason: decision.reason, manifest: nil)

        case .automatic:
            let manifest = try await createBackup(.automatic, decision.reason)
            try await settings.set(String(now), for: Self.keyLastAutomaticAt)
            try await settings.set(fingerprint, for: Self.keyFingerprint)
            return Outcome(action: .automatic, reason: decision.reason, manifest: manifest)

        case .incremental:
            let manifest = try await createBackup(.incremental, decision.reason)
            try await settings.set(String(now), for: Self.keyLastIncrementalAt)
            try await settings.set(fingerprint, for: Self.keyFingerprint)
            return Outcome(action: .incremental, reason: decision.reason, manifest: manifest)
        }
    }

    // MARK: - 数据指纹

    /// 轻量指纹：各核心表的行数 + 关键时间列最大值。表不存在时自动跳过（兼容早期库）。
    public func currentFingerprint() async throws -> String {
        try await database.dbQueue.read { db in
            var parts: [String] = []
            for spec in Self.fingerprintSpecs {
                guard try db.tableExists(spec.table) else { continue }
                let columns = Set(try db.columns(in: spec.table).map(\.name))
                var expressions = ["count(*)"]
                for column in spec.timeColumns where columns.contains(column) {
                    expressions.append("coalesce(max(\(column)),0)")
                }
                let sql = "SELECT \(expressions.joined(separator: ", ")) FROM \(spec.table)"
                let values = try Row.fetchOne(db, sql: sql)
                let line = spec.table + ":" + expressions.indices
                    .map { String(describing: values?[$0] ?? DatabaseValue.null) }
                    .joined(separator: ",")
                parts.append(line)
            }
            return SHA256.hash(parts.joined(separator: "|"))
        }
    }

    private struct FingerprintSpec: Sendable {
        var table: String
        var timeColumns: [String]
    }

    private static let fingerprintSpecs: [FingerprintSpec] = [
        FingerprintSpec(table: "messages", timeColumns: ["created_at"]),
        FingerprintSpec(table: "memories", timeColumns: ["last_recalled_at", "first_seen_at"]),
        FingerprintSpec(table: "diary_entries", timeColumns: ["updated_at", "deleted_at"]),
        FingerprintSpec(table: "diary_entry_versions", timeColumns: ["created_at"]),
        FingerprintSpec(table: "persona_versions", timeColumns: ["created_at"]),
        FingerprintSpec(table: "model_configs", timeColumns: ["updated_at"])
    ]

    /// 空库不做自动备份，避免产生一堆无意义文件
    private func hasData() async throws -> Bool {
        try await database.dbQueue.read { db in
            for table in ["messages", "memories", "diary_entries"] {
                guard try db.tableExists(table) else { continue }
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
                if count > 0 { return true }
            }
            return false
        }
    }

    private func intSetting(_ key: String) async -> Int64? {
        guard let raw = try? await settings.string(for: key), let value = Int64(raw) else {
            return nil
        }
        return value
    }
}
