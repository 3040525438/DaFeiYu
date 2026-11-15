import Foundation

// MARK: - 附件引用与清理（D57）

/// 一个附件的引用情况。
///
/// `liveReferences` 只统计**未软删消息**的引用：已删除消息留下的关联行视为陈旧引用，
/// 不应阻止用户清理附件，但也不主动删除，便于恢复。
public struct AttachmentReference: Sendable, Equatable {
    public var attachmentID: String
    /// 全部关联消息数（含已软删消息）
    public var totalReferences: Int
    /// 未软删消息的引用数
    public var liveReferences: Int
    public var messageIDs: [String]

    /// 只要还有活引用就算"使用中"，删除前必须让用户确认
    public var isInUse: Bool { liveReferences > 0 }

    public init(
        attachmentID: String,
        totalReferences: Int,
        liveReferences: Int,
        messageIDs: [String]
    ) {
        self.attachmentID = attachmentID
        self.totalReferences = totalReferences
        self.liveReferences = liveReferences
        self.messageIDs = messageIDs
    }
}

/// 附件库列表项（D57）：附件本体 + 引用统计。
///
/// 界面据此区分"使用中 / 仅有陈旧引用 / 完全无引用"，
/// 避免把已删除消息留下的陈旧关联当成仍在使用。
public struct AttachmentLibraryItem: Sendable, Equatable, Identifiable {
    public var record: AttachmentRecord
    public var totalReferences: Int
    public var liveReferences: Int

    public var id: String { record.id }

    /// 仍有未删除消息引用：默认禁止删除
    public var isInUse: Bool { liveReferences > 0 }

    /// 只剩已删除消息的关联：可以清理，但删除前要提示会失去恢复线索
    public var hasStaleReferencesOnly: Bool { liveReferences == 0 && totalReferences > 0 }

    public init(record: AttachmentRecord, totalReferences: Int, liveReferences: Int) {
        self.record = record
        self.totalReferences = totalReferences
        self.liveReferences = liveReferences
    }
}

public enum AttachmentReferenceError: Error, Equatable, CustomStringConvertible {
    case notFound
    /// 仍被消息引用，且调用方未要求强制删除
    case inUse(messageIDs: [String])

    public var description: String {
        switch self {
        case .notFound:
            return "附件不存在"
        case let .inUse(messageIDs):
            return "附件仍被 \(messageIDs.count) 条消息引用，需确认后再删除"
        }
    }
}

/// 附件引用检查与清理（D57）。
///
/// 口径：
/// - 删除前必须先查引用，被活消息引用时默认拒绝删除（抛 `inUse`），由上层弹确认；
/// - `force == true` 时先解除全部关联再软删附件（**不删磁盘文件、不删派生文本**）；
/// - 批量清理只处理"无活引用"的附件，返回删除与跳过数量，绝不静默删被引用数据。
public protocol AttachmentReferenceService: Sendable {
    func references(attachmentID: String) async throws -> AttachmentReference

    /// 附件库列表：按创建时间倒序，逐条带引用统计。
    /// `includeDeleted == false` 时只返回未软删附件。
    func library(includeDeleted: Bool, limit: Int, offset: Int) async throws -> [AttachmentLibraryItem]

    /// D27：按 id 取附件记录（搜索命中后预览原图用）。不存在或已硬删返回 nil。
    func record(id: String) async throws -> AttachmentRecord?

    /// 删除附件（软删）。被引用且 `force == false` 时抛 `inUse`。
    func deleteAttachment(id: String, at millis: Int64, force: Bool) async throws

    /// 解除该附件的全部消息关联，返回解除条数。
    @discardableResult
    func unlinkAll(attachmentID: String) async throws -> Int

    /// 早于指定时间且无任何关联的附件（清理候选，只报告不删除）
    func cleanupCandidates(before millis: Int64, limit: Int) async throws -> [AttachmentRecord]

    /// 批量清理：逐个检查引用，被活消息引用的跳过。返回 (已删除, 因被引用跳过)。
    func cleanup(
        attachmentIDs: [String],
        at millis: Int64
    ) async throws -> (deleted: Int, skippedInUse: Int)
}
