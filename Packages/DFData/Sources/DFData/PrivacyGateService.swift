import Foundation
import GRDB
import DFCore

public enum PrivacyUnlockOutcome: Sendable, Equatable {
    case unlocked
    case wrongPasscode(remainingAttempts: Int)
    case lockedOut(until: Int64)
    case notConfigured
}

/// 隐私门禁与数据删除的落地实现（W9）。
///
/// - 口令只存加盐哈希；失败计数与锁定窗口落 `settings`，重启后仍生效；
/// - 生物识别成功由系统回调给出，**失败不计入口令失败次数**；
/// - 隐私授权记录可查、可撤，撤销后调用方必须重新询问；
/// - "删除全部数据"要求逐字确认短语，并明确告知密钥销毁后备份不可解密。
public final class PrivacyGateService: @unchecked Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Int64
    private let fileManager = FileManager.default

    private static let settingsKey = "privacy.settings"
    private static let stateKey = "privacy.state"
    private static let consentsKey = "privacy.consents"

    /// 可被"删除全部数据"清理的业务表（不含 schema 台账）
    public static let deletableTables: [String] = BackupService.tableOrder + [
        "proposals", "attachments", "message_attachments", "attachment_texts", "image_analyses"
    ]

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    // MARK: - 设置与状态

    public func settings() async throws -> PrivacySettings {
        guard let json = try await readSetting(Self.settingsKey),
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(PrivacySettings.self, from: data) else {
            return .default
        }
        return value
    }

    public func saveSettings(_ value: PrivacySettings) async throws {
        let data = try JSONEncoder().encode(value)
        try await writeSetting(Self.settingsKey, value: String(data: data, encoding: .utf8) ?? "{}")
    }

    /// 设置口令（传入 nil 表示关闭口令）
    public func configurePasscode(_ passcode: String?, biometrics: Bool? = nil) async throws {
        var value = try await settings()
        if let passcode {
            let trimmed = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
            value.passcodeHash = PrivacyGate.hashPasscode(trimmed)
            value.lockEnabled = true
        } else {
            value.passcodeHash = nil
            value.lockEnabled = false
        }
        if let biometrics { value.biometricsEnabled = biometrics }
        try await saveSettings(value)
    }

    public func state() async throws -> PrivacyGateState {
        guard let json = try await readSetting(Self.stateKey),
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(PrivacyGateState.self, from: data) else {
            return .initial
        }
        return value
    }

    public func saveState(_ value: PrivacyGateState) async throws {
        let data = try JSONEncoder().encode(value)
        try await writeSetting(Self.stateKey, value: String(data: data, encoding: .utf8) ?? "{}")
    }

    // MARK: - 生命周期

    @discardableResult
    public func handleLaunch(at millis: Int64? = nil) async throws -> PrivacyGateDecision {
        let timestamp = millis ?? now()
        let settings = try await settings()
        var state = try await state()
        // 启动一律先锁（若启用了门禁），避免冷启动窗口泄露
        if settings.lockEnabled, settings.passcodeHash != nil {
            state = PrivacyGate.lock(state)
        }
        try await saveState(state)
        return PrivacyGate.decision(settings: settings, state: state, event: .appLaunch, at: timestamp)
    }

    @discardableResult
    public func handleBackground(at millis: Int64? = nil) async throws -> PrivacyGateState {
        let timestamp = millis ?? now()
        let state = PrivacyGate.enterBackground(try await state(), at: timestamp)
        try await saveState(state)
        return state
    }

    @discardableResult
    public func handleForeground(at millis: Int64? = nil) async throws -> PrivacyGateDecision {
        let timestamp = millis ?? now()
        let settings = try await settings()
        var state = try await state()
        if PrivacyGate.shouldLockOnForeground(settings: settings, state: state, at: timestamp) {
            state = PrivacyGate.lock(state)
            try await saveState(state)
        }
        return PrivacyGate.decision(settings: settings, state: state, event: .foreground, at: timestamp)
    }

    @discardableResult
    public func lockNow() async throws -> PrivacyGateState {
        let state = PrivacyGate.lock(try await state())
        try await saveState(state)
        return state
    }

    /// 口令解锁：锁定窗口内直接拒绝，窗口外失败累计到上限进入冷却。
    @discardableResult
    public func attemptPasscode(_ passcode: String, at millis: Int64? = nil) async throws -> PrivacyUnlockOutcome {
        let timestamp = millis ?? now()
        let settings = try await settings()
        var state = try await state()

        guard settings.lockEnabled, settings.passcodeHash != nil else {
            return .notConfigured
        }
        switch PrivacyGate.decision(settings: settings, state: state, event: .unlockAttempt, at: timestamp) {
        case .lockedOut(let until):
            return .lockedOut(until: until)
        case .allowed:
            return .unlocked
        case .requiresUnlock:
            break
        }

        if PrivacyGate.verify(passcode: passcode, settings: settings) {
            state = PrivacyGate.registerSuccess(state, at: timestamp)
            try await saveState(state)
            return .unlocked
        }

        state = PrivacyGate.registerFailure(state, settings: settings, at: timestamp)
        try await saveState(state)
        if let until = state.lockedUntil {
            return .lockedOut(until: until)
        }
        return .wrongPasscode(remainingAttempts: max(settings.maxFailedAttempts - state.failedAttempts, 0))
    }

    /// 生物识别成功（系统已验证通过）
    @discardableResult
    public func biometricUnlocked(at millis: Int64? = nil) async throws -> PrivacyUnlockOutcome {
        let timestamp = millis ?? now()
        let settings = try await settings()
        guard settings.lockEnabled, settings.biometricsEnabled else { return .notConfigured }
        let state = PrivacyGate.registerSuccess(try await state(), at: timestamp)
        try await saveState(state)
        return .unlocked
    }

    // MARK: - 授权记录

    public func consents() async throws -> [PrivacyConsent] {
        guard let json = try await readSetting(Self.consentsKey),
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([PrivacyConsent].self, from: data) else {
            return []
        }
        return value
    }

    @discardableResult
    public func setConsent(
        _ kind: PrivacyConsentKind,
        granted: Bool,
        note: String = "",
        at millis: Int64? = nil
    ) async throws -> PrivacyConsent {
        let timestamp = millis ?? now()
        var all = try await consents()
        all.removeAll { $0.kind == kind }
        let consent = PrivacyConsent(kind: kind, granted: granted, updatedAt: timestamp, note: note)
        all.append(consent)
        all.sort { $0.kind.rawValue < $1.kind.rawValue }
        let data = try JSONEncoder().encode(all)
        try await writeSetting(Self.consentsKey, value: String(data: data, encoding: .utf8) ?? "[]")
        return consent
    }

    public func isGranted(_ kind: PrivacyConsentKind) async throws -> Bool {
        let all = try await consents()
        return all.first { $0.kind == kind }?.granted ?? false
    }

    // MARK: - 数据删除

    public func deletionPlan() async throws -> DataDeletionPlan {
        let items = try await database.dbQueue.read { db -> [DataDeletionItem] in
            var result: [DataDeletionItem] = []
            for table in Self.deletableTables {
                guard try db.tableExists(table) else { continue }
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
                result.append(
                    DataDeletionItem(
                        id: table,
                        title: Self.title(for: table),
                        detail: Self.detail(for: table),
                        count: count
                    )
                )
            }
            return result
        }
        let total = items.reduce(0) { $0 + $1.count }
        return DataDeletionPlan(
            items: items,
            totalCount: total,
            keyLossWarning: DataDeletionPlan.keyLossWarningText
        )
    }

    /// 彻底删除：必须逐字输入确认短语；返回各表删除行数。
    @discardableResult
    public func deleteAll(
        confirmation: String,
        includeAttachments: Bool = true,
        at millis: Int64? = nil
    ) async throws -> [String: Int] {
        guard confirmation == DataDeletionPlan.confirmationPhrase else {
            throw PrivacyError.confirmationMismatch
        }

        let counts = try await database.write { db -> [String: Int] in
            var result: [String: Int] = [:]
            for table in Self.deletableTables.reversed() {
                guard try db.tableExists(table) else { continue }
                let before = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
                try db.execute(sql: "DELETE FROM \(table)")
                result[table] = before
            }
            // 全文索引一并清空，避免删除后仍能搜到残留
            for fts in ["memory_fts", "message_fts", "diary_fts", "attachment_text_fts"] {
                guard try db.tableExists(fts) else { continue }
                try db.execute(sql: "DELETE FROM \(fts)")
            }
            return result
        }

        if includeAttachments {
            let root = database.paths.attachmentsRoot
            if let files = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
        return counts
    }

    // MARK: - 内部

    private func readSetting(_ key: String) async throws -> String? {
        try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    private func writeSetting(_ key: String, value: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    private static func title(for table: String) -> String {
        switch table {
        case "conversations": return "会话"
        case "messages": return "聊天消息"
        case "memories": return "记忆（含来源与版本）"
        case "memory_sources": return "记忆来源引用"
        case "memory_versions": return "记忆历史版本"
        case "diary_entries": return "日记"
        case "diary_entry_versions": return "日记历史版本"
        case "personas": return "人格"
        case "persona_items": return "人格条目"
        case "persona_versions": return "人格版本"
        case "settings": return "设置"
        case "proposals": return "待确认提案"
        case "attachments": return "附件索引"
        case "message_attachments": return "消息与附件关联"
        case "attachment_texts": return "附件转写/OCR 文本"
        case "image_analyses": return "图片理解结果"
        default: return table
        }
    }

    private static func detail(for table: String) -> String {
        switch table {
        case "memories": return "删除后不可恢复；备份中的内容也会因为密钥销毁而无法解密"
        case "attachments", "message_attachments": return "同时会删除本地附件文件"
        default: return "仅删除本机数据"
        }
    }
}

public enum PrivacyError: Error, Equatable, CustomStringConvertible {
    case confirmationMismatch

    public var description: String {
        switch self {
        case .confirmationMismatch:
            return "确认短语不正确，未执行删除（需逐字输入：\(DataDeletionPlan.confirmationPhrase)）"
        }
    }
}
