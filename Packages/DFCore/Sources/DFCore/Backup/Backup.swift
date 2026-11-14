import Foundation

// MARK: - 备份与恢复（W9）

public enum BackupKind: String, Codable, Sendable, CaseIterable {
    case manual
    case automatic
    case incremental
    case external
    case safety
}

public enum BackupStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case verified
}

public struct BackupManifest: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: BackupKind
    public var scope: String
    public var status: BackupStatus
    public var schemaVersion: String
    public var appVersion: String
    public var fileName: String
    public var relPath: String
    public var byteSize: Int64
    public var sha256: String?
    /// 默认加密（D20）：明文导出必须由 UI 二次确认后显式写 false
    public var isEncrypted: Bool
    public var encryptionHint: String?
    public var itemCountsJSON: String
    public var note: String?
    public var createdAt: Int64
    public var finishedAt: Int64?
    public var verifiedAt: Int64?
    public var retentionUntil: Int64?

    public var isUsable: Bool {
        status == .completed || status == .verified
    }

    public init(
        id: String,
        kind: BackupKind,
        scope: String,
        status: BackupStatus,
        schemaVersion: String,
        appVersion: String,
        fileName: String,
        relPath: String,
        byteSize: Int64,
        sha256: String?,
        isEncrypted: Bool,
        encryptionHint: String?,
        itemCountsJSON: String,
        note: String?,
        createdAt: Int64,
        finishedAt: Int64?,
        verifiedAt: Int64?,
        retentionUntil: Int64?
    ) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.status = status
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.fileName = fileName
        self.relPath = relPath
        self.byteSize = byteSize
        self.sha256 = sha256
        self.isEncrypted = isEncrypted
        self.encryptionHint = encryptionHint
        self.itemCountsJSON = itemCountsJSON
        self.note = note
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.verifiedAt = verifiedAt
        self.retentionUntil = retentionUntil
    }
}

public struct RestoreLog: Sendable, Equatable, Identifiable {
    public var id: String
    public var backupID: String?
    public var mode: String
    public var status: String
    public var previewJSON: String
    public var isCompatible: Bool
    public var isSpaceOK: Bool
    public var safetyBackupID: String?
    public var restoredCountsJSON: String
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var error: String?

    public init(
        id: String,
        backupID: String?,
        mode: String,
        status: String,
        previewJSON: String,
        isCompatible: Bool,
        isSpaceOK: Bool,
        safetyBackupID: String?,
        restoredCountsJSON: String,
        startedAt: Int64,
        finishedAt: Int64?,
        error: String?
    ) {
        self.id = id
        self.backupID = backupID
        self.mode = mode
        self.status = status
        self.previewJSON = previewJSON
        self.isCompatible = isCompatible
        self.isSpaceOK = isSpaceOK
        self.safetyBackupID = safetyBackupID
        self.restoredCountsJSON = restoredCountsJSON
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
    }
}

public enum BackupError: Error, Equatable, CustomStringConvertible {
    case notFound
    case invalidKind(String)
    case restoreAlreadyRunning
    case incompatibleSchema(String)
    case insufficientSpace

    public var description: String {
        switch self {
        case .notFound: return "备份记录不存在"
        case .invalidKind(let value): return "非法的备份类型：\(value)"
        case .restoreAlreadyRunning: return "已有恢复任务在进行中"
        case .incompatibleSchema(let value): return "备份版本不兼容：\(value)"
        case .insufficientSpace: return "可用空间不足"
        }
    }
}

/// 恢复前的检查结果：必须三项都过才允许落地（D42）。
public struct RestorePrecheck: Codable, Sendable, Equatable {
    public var backupID: String
    public var backupSchemaVersion: String
    public var currentSchemaVersion: String
    public var isCompatible: Bool
    public var isSpaceOK: Bool
    public var itemCountsJSON: String

    public var canProceed: Bool { isCompatible && isSpaceOK }
}

public protocol BackupRepository: Sendable {
    /// 新建"待写入"清单；文件落盘后调用 `markFinished`。
    @discardableResult
    func create(
        kind: BackupKind,
        scope: String,
        schemaVersion: String,
        appVersion: String,
        fileName: String,
        relPath: String,
        isEncrypted: Bool,
        encryptionHint: String?,
        note: String?,
        at millis: Int64
    ) async throws -> BackupManifest

    func markFinished(id: String, byteSize: Int64, sha256: String?, itemCountsJSON: String, at millis: Int64) async throws
    func markFailed(id: String, at millis: Int64) async throws
    func markVerified(id: String, at millis: Int64) async throws

    func manifest(id: String) async throws -> BackupManifest?
    func manifests(kind: BackupKind?, limit: Int) async throws -> [BackupManifest]
    func latest(kind: BackupKind?) async throws -> BackupManifest?
    func delete(id: String) async throws

    /// 保留策略：保留最近 `keepCount` 份，其余可清理；`verified` 与 `safety` 永不自动清理（D43）。
    func prunable(keepCount: Int, at millis: Int64) async throws -> [BackupManifest]

    func startRestore(backupID: String?, mode: String, previewJSON: String,
                      isCompatible: Bool, isSpaceOK: Bool, safetyBackupID: String?,
                      at millis: Int64) async throws -> RestoreLog
    func finishRestore(id: String, status: String, restoredCountsJSON: String,
                       error: String?, at millis: Int64) async throws
    func restoreLogs(limit: Int) async throws -> [RestoreLog]

    /// 备份占用总字节（存储分类展示，D66）
    func totalBytes() async throws -> Int64
}
