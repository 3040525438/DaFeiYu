import Foundation

// MARK: - AstrBot 全量导入（W9 / 决策 38–40、S-01 / S-02 / S-09）

/// 数据源路径。所有源文件一律**只读**：导入器不写、不改、不删。
/// 未提供的数据源在本次导入中跳过，并在报告中体现为 0。
public struct AstrBotSourcePaths: Sendable, Equatable {
    /// 聊天记录库：`data/plugin_data/chat_memory/chat_memory.db`
    public var chatMemoryDatabase: URL?
    /// 长期记忆库：`diary/memory.db`
    public var longTermMemoryDatabase: URL?
    /// 人格库：`data/data_v4.db`
    public var personaDatabase: URL?
    /// 日记目录：`diary/`（只取 `yyyy-MM-dd.md`，`txt/` 视为镜像）
    public var diaryDirectory: URL?
    /// 信件目录：`letters/`
    public var lettersDirectory: URL?
    /// 读书笔记目录：`books/notes/`
    public var bookNotesDirectory: URL?
    /// 关系账本：`data/plugin_data/astrbot_plugin_private_companion/companions.json`
    public var companionLedgerJSON: URL?

    public init(
        chatMemoryDatabase: URL? = nil,
        longTermMemoryDatabase: URL? = nil,
        personaDatabase: URL? = nil,
        diaryDirectory: URL? = nil,
        lettersDirectory: URL? = nil,
        bookNotesDirectory: URL? = nil,
        companionLedgerJSON: URL? = nil
    ) {
        self.chatMemoryDatabase = chatMemoryDatabase
        self.longTermMemoryDatabase = longTermMemoryDatabase
        self.personaDatabase = personaDatabase
        self.diaryDirectory = diaryDirectory
        self.lettersDirectory = lettersDirectory
        self.bookNotesDirectory = bookNotesDirectory
        self.companionLedgerJSON = companionLedgerJSON
    }

    /// 至少提供一个数据源才允许启动导入
    public var hasAnySource: Bool {
        [chatMemoryDatabase, longTermMemoryDatabase, personaDatabase,
         diaryDirectory, lettersDirectory, bookNotesDirectory, companionLedgerJSON]
            .contains { $0 != nil }
    }
}

/// 导入选项。
public struct AstrBotImportOptions: Sendable, Equatable {
    /// 预演：完整跑一遍映射与校验，然后整体回滚，只留批次报告
    public var isDryRun: Bool
    /// 会话标题前缀
    public var conversationTitlePrefix: String
    /// 迁移后核心人格的显示名
    public var personaName: String
    /// 是否导入信件与读书笔记
    public var importsDocuments: Bool
    /// 是否把关系账本收进待处理区
    public var importsRelationshipLedger: Bool
    /// 源文件暂存目录：设置后先把源文件复制到该目录再打开，原件完全不触碰
    public var stagingDirectory: URL?

    public init(
        isDryRun: Bool = true,
        conversationTitlePrefix: String = "AstrBot 迁移",
        personaName: String = "大肥鱼",
        importsDocuments: Bool = true,
        importsRelationshipLedger: Bool = true,
        stagingDirectory: URL? = nil
    ) {
        self.isDryRun = isDryRun
        self.conversationTitlePrefix = conversationTitlePrefix
        self.personaName = personaName
        self.importsDocuments = importsDocuments
        self.importsRelationshipLedger = importsRelationshipLedger
        self.stagingDirectory = stagingDirectory
    }
}

/// 批次状态。字符串值与 `astrbot_migration_batches.status` 一致。
public enum AstrBotImportStatus: String, Sendable, Equatable {
    case running
    case succeeded
    case dryRunSucceeded = "dry_run_succeeded"
    case failed
    case rolledBack = "rolled_back"
}

/// 导入涉及的实体类型（与 `astrbot_id_map.entity_kind` 口径一致）。
public enum AstrBotEntityKind: String, Sendable, Equatable, CaseIterable {
    case conversation
    case message
    case memory
    case diary
    case persona
    case personaItem = "persona_item"
    case document
}

/// 待处理原因码。新增值只能追加，不改已有字符串。
public enum AstrBotPendingReason: String, Sendable, Equatable, CaseIterable {
    case unknownRole = "unknown_role"
    case systemEvent = "system_event"
    case mediaMissing = "media_missing"
    case toolRecord = "tool_record"
    case mediaArchive = "media_archive"
    case invalidTimestamp = "invalid_timestamp"
    case emptyContent = "empty_content"
    case invalidDay = "invalid_day"
    case diaryDateConflict = "diary_date_conflict"
    case unrecognizedDiaryFile = "unrecognized_diary_file"
    case personaConflict = "persona_conflict"
    case relationshipLedger = "relationship_ledger"
    case replyTargetMissing = "reply_target_missing"
    case unsupportedContentKind = "unsupported_content_kind"
}

/// 导入计数。覆盖式校验的唯一依据：每个源行必须落入"导入 / 重复 / 待处理"之一。
public struct AstrBotImportCounts: Codable, Sendable, Equatable {
    public var sourceChatRecords: Int = 0
    public var sourceToolRecords: Int = 0
    public var sourceMediaArchives: Int = 0

    public var messagesNew: Int = 0
    public var messagesDuplicate: Int = 0
    public var messagesPending: Int = 0

    public var sourceMemories: Int = 0
    public var memoriesNew: Int = 0
    public var memoriesDuplicate: Int = 0
    public var memoriesPending: Int = 0

    public var sourceDiaryFiles: Int = 0
    public var diariesNew: Int = 0
    public var diaryDuplicates: Int = 0
    public var diaryMirrors: Int = 0
    public var diaryPending: Int = 0

    public var sourcePersonaRows: Int = 0
    public var personaRowsImported: Int = 0
    public var personaPending: Int = 0
    public var personaItemsNew: Int = 0

    public var sourceDocuments: Int = 0
    public var documentsNew: Int = 0
    public var documentsDuplicate: Int = 0
    public var documentsPending: Int = 0

    public var sourceLedgerUsers: Int = 0
    public var ledgerPending: Int = 0

    /// 附加异常（不影响源行覆盖，但必须可见）
    public var pendingMediaMissing: Int = 0
    public var pendingReplyTargetMissing: Int = 0
    public var pendingToolRecords: Int = 0
    public var pendingMediaArchives: Int = 0

    public var pendingTotal: Int = 0

    public init() {}

    /// 源行覆盖校验：不一致说明有行被静默丢弃。
    public var coverageProblems: [String] {
        var problems: [String] = []
        if sourceChatRecords != messagesNew + messagesDuplicate + messagesPending {
            problems.append(
                "聊天：源 \(sourceChatRecords) ≠ 新增 \(messagesNew) + 重复 \(messagesDuplicate) + 待处理 \(messagesPending)"
            )
        }
        if sourceMemories != memoriesNew + memoriesDuplicate + memoriesPending {
            problems.append(
                "记忆：源 \(sourceMemories) ≠ 新增 \(memoriesNew) + 重复 \(memoriesDuplicate) + 待处理 \(memoriesPending)"
            )
        }
        if sourceDiaryFiles != diariesNew + diaryDuplicates + diaryMirrors + diaryPending {
            problems.append(
                "日记：源 \(sourceDiaryFiles) ≠ 新增 \(diariesNew) + 重复 \(diaryDuplicates) + 镜像 \(diaryMirrors) + 待处理 \(diaryPending)"
            )
        }
        if sourcePersonaRows != personaRowsImported + personaPending {
            problems.append(
                "人格：源 \(sourcePersonaRows) ≠ 导入 \(personaRowsImported) + 待处理 \(personaPending)"
            )
        }
        if sourceDocuments != documentsNew + documentsDuplicate + documentsPending {
            problems.append(
                "文档：源 \(sourceDocuments) ≠ 新增 \(documentsNew) + 重复 \(documentsDuplicate) + 待处理 \(documentsPending)"
            )
        }
        if sourceLedgerUsers != ledgerPending {
            problems.append("关系账本：源 \(sourceLedgerUsers) ≠ 待处理 \(ledgerPending)")
        }
        if sourceToolRecords != pendingToolRecords {
            problems.append("工具记录：源 \(sourceToolRecords) ≠ 待处理 \(pendingToolRecords)")
        }
        if sourceMediaArchives != pendingMediaArchives {
            problems.append("媒体归档：源 \(sourceMediaArchives) ≠ 待处理 \(pendingMediaArchives)")
        }
        return problems
    }
}

/// 一次导入的对外报告。
public struct AstrBotImportReport: Sendable, Equatable {
    public var batchID: String
    public var status: AstrBotImportStatus
    public var isDryRun: Bool
    public var sourceHash: String
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var counts: AstrBotImportCounts
    public var pendingByReason: [String: Int]

    public init(
        batchID: String,
        status: AstrBotImportStatus,
        isDryRun: Bool,
        sourceHash: String,
        startedAt: Int64,
        finishedAt: Int64?,
        counts: AstrBotImportCounts,
        pendingByReason: [String: Int]
    ) {
        self.batchID = batchID
        self.status = status
        self.isDryRun = isDryRun
        self.sourceHash = sourceHash
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.counts = counts
        self.pendingByReason = pendingByReason
    }
}

/// 批次摘要（用于界面列表）。
public struct AstrBotBatchSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var isDryRun: Bool
    public var status: String
    public var sourceRef: String
    public var sourceHash: String?
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var error: String?
    public var counts: AstrBotImportCounts

    public init(
        id: String,
        isDryRun: Bool,
        status: String,
        sourceRef: String,
        sourceHash: String?,
        startedAt: Int64,
        finishedAt: Int64?,
        error: String?,
        counts: AstrBotImportCounts
    ) {
        self.id = id
        self.isDryRun = isDryRun
        self.status = status
        self.sourceRef = sourceRef
        self.sourceHash = sourceHash
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.counts = counts
    }
}

/// 待处理区条目：未识别/冲突数据保留原始内容，等待人工决定。
public struct AstrBotPendingItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var batchID: String
    public var entityKind: String
    public var sourceID: String?
    public var reasonCode: String
    public var rawJSON: String
    public var status: String
    public var resolvedTargetID: String?
    public var createdAt: Int64
    public var resolvedAt: Int64?

    public init(
        id: String,
        batchID: String,
        entityKind: String,
        sourceID: String?,
        reasonCode: String,
        rawJSON: String,
        status: String,
        resolvedTargetID: String?,
        createdAt: Int64,
        resolvedAt: Int64?
    ) {
        self.id = id
        self.batchID = batchID
        self.entityKind = entityKind
        self.sourceID = sourceID
        self.reasonCode = reasonCode
        self.rawJSON = rawJSON
        self.status = status
        self.resolvedTargetID = resolvedTargetID
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

/// 回滚结果：只删本批次造出来的东西。
public struct AstrBotRollbackReport: Sendable, Equatable {
    public var batchID: String
    public var status: AstrBotImportStatus
    public var deletedMessages: Int
    public var deletedConversations: Int
    public var deletedMemories: Int
    public var deletedDiaries: Int
    public var deletedPersonaItems: Int
    public var deletedPersonas: Int
    public var deletedPending: Int
    public var deletedIDMaps: Int

    public init(
        batchID: String,
        status: AstrBotImportStatus,
        deletedMessages: Int,
        deletedConversations: Int,
        deletedMemories: Int,
        deletedDiaries: Int,
        deletedPersonaItems: Int,
        deletedPersonas: Int,
        deletedPending: Int,
        deletedIDMaps: Int
    ) {
        self.batchID = batchID
        self.status = status
        self.deletedMessages = deletedMessages
        self.deletedConversations = deletedConversations
        self.deletedMemories = deletedMemories
        self.deletedDiaries = deletedDiaries
        self.deletedPersonaItems = deletedPersonaItems
        self.deletedPersonas = deletedPersonas
        self.deletedPending = deletedPending
        self.deletedIDMaps = deletedIDMaps
    }
}

public enum AstrBotImportError: Error, Equatable, CustomStringConvertible {
    case noSource
    case sourceMissing(String)
    case sourceUnreadable(String)
    case sourceChanged(String)
    case invalidBatch(String)
    case alreadyRolledBack(String)
    case rollbackNotAllowed(String)
    case coverageMismatch([String])
    case pendingNotFound(String)

    public var description: String {
        switch self {
        case .noSource:
            return "未提供任何 AstrBot 数据源"
        case .sourceMissing(let path):
            return "数据源不存在：\(path)"
        case .sourceUnreadable(let path):
            return "数据源无法读取：\(path)"
        case .sourceChanged(let path):
            return "导入期间源文件发生变化，已中止：\(path)"
        case .invalidBatch(let id):
            return "导入批次不存在：\(id)"
        case .alreadyRolledBack(let id):
            return "该批次已回滚：\(id)"
        case .rollbackNotAllowed(let reason):
            return "当前批次不允许回滚：\(reason)"
        case .coverageMismatch(let problems):
            return "导入覆盖校验失败：\(problems.joined(separator: "；"))"
        case .pendingNotFound(let id):
            return "待处理条目不存在：\(id)"
        }
    }
}

/// AstrBot 导入器协议（DFData 提供实现；App 只依赖协议）。
public protocol AstrBotImporting: Sendable {
    func run(source: AstrBotSourcePaths, options: AstrBotImportOptions) async throws -> AstrBotImportReport
    func rollback(batchID: String, at millis: Int64) async throws -> AstrBotRollbackReport
    func batches(limit: Int) async throws -> [AstrBotBatchSummary]
    func pendingItems(batchID: String, limit: Int) async throws -> [AstrBotPendingItem]
    func resolvePending(id: String, targetID: String?, at millis: Int64) async throws
}
