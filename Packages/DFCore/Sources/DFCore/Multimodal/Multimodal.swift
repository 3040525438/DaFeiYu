import Foundation

// MARK: - 附件（W4）

// 附件记录类型复用 `Models/Attachment.swift` 的 `AttachmentRecord`（v10 已扩展媒体指标字段）。

/// 新建附件的输入。`sha256` 是去重键：同一内容只保留一行。
public struct NewAttachment: Sendable, Equatable {
    public var sha256: String
    public var kind: String
    public var relPath: String
    public var byteSize: Int64
    public var mime: String
    public var createdAt: Int64

    public init(
        sha256: String,
        kind: String,
        relPath: String,
        byteSize: Int64,
        mime: String,
        createdAt: Int64
    ) {
        self.sha256 = sha256
        self.kind = kind
        self.relPath = relPath
        self.byteSize = byteSize
        self.mime = mime
        self.createdAt = createdAt
    }
}

public protocol AttachmentRepository: Sendable {
    /// 按 `sha256` 去重写入；已存在则原样返回既有行（不覆盖元数据）。
    func ensure(_ attachment: NewAttachment) async throws -> AttachmentRecord
    func attachment(id: String) async throws -> AttachmentRecord?
    /// 某条消息的附件，按 `message_attachments.sort` 升序；默认不含已软删
    func attachments(inMessage messageID: String, includeDeleted: Bool) async throws -> [AttachmentRecord]
    /// 引用了该附件的消息 id（删除前的影响面检查，D57）
    func messageIDs(usingAttachment id: String) async throws -> [String]
    /// 早于 `millis` 且未被任何消息引用的附件（批量清理候选，只报告不删除）
    func unreferenced(before millis: Int64, limit: Int) async throws -> [AttachmentRecord]
    /// 写入尺寸/时长/缩略图（nil 表示"不知道"，不覆盖已有值需显式传值）
    func setMetrics(
        id: String,
        width: Int?,
        height: Int?,
        durationMs: Int?,
        thumbnailRelPath: String?
    ) async throws
    func link(messageID: String, attachmentID: String, sort: Int) async throws
    func unlink(messageID: String, attachmentID: String) async throws
    /// 软删附件（不删文件、不删派生文本）；已删则幂等
    func softDelete(id: String, reason: String?, at millis: Int64) async throws
    func restore(id: String) async throws
}

// MARK: - OCR / 语音转写

public enum AttachmentTextKind: String, Sendable, CaseIterable {
    case ocr
    case transcript
}

/// 派生文本：同一附件同一 kind 只有一条，重算即覆盖。
public struct AttachmentTextRecord: Sendable, Equatable {
    public var attachmentID: String
    public var kind: AttachmentTextKind
    public var text: String
    public var language: String?
    public var engine: String
    public var confidence: Double?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        attachmentID: String,
        kind: AttachmentTextKind,
        text: String,
        language: String?,
        engine: String,
        confidence: Double?,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.attachmentID = attachmentID
        self.kind = kind
        self.text = text
        self.language = language
        self.engine = engine
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol AttachmentTextRepository: Sendable {
    /// 写入/覆盖派生文本并同步全文索引；空文本视为清除该 kind。
    @discardableResult
    func upsert(
        attachmentID: String,
        kind: AttachmentTextKind,
        text: String,
        language: String?,
        engine: String,
        confidence: Double?,
        at millis: Int64
    ) async throws -> AttachmentTextRecord?

    func text(attachmentID: String, kind: AttachmentTextKind) async throws -> AttachmentTextRecord?
    func texts(attachmentID: String) async throws -> [AttachmentTextRecord]
    func remove(attachmentID: String, kind: AttachmentTextKind) async throws
    /// 按关键词搜索派生文本，返回命中的附件 id（按相关度升序）
    func search(query: String, limit: Int) async throws -> [String]
}

// MARK: - 多图理解

public struct ImageAnalysisRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var conversationID: String?
    public var messageID: String?
    public var attachmentIDs: [String]
    public var prompt: String
    public var result: String
    public var modelConfigID: String?
    /// pending / running / done / failed
    public var status: String
    public var createdAt: Int64
    public var finishedAt: Int64?

    public init(
        id: String,
        conversationID: String?,
        messageID: String?,
        attachmentIDs: [String],
        prompt: String,
        result: String,
        modelConfigID: String?,
        status: String,
        createdAt: Int64,
        finishedAt: Int64?
    ) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.attachmentIDs = attachmentIDs
        self.prompt = prompt
        self.result = result
        self.modelConfigID = modelConfigID
        self.status = status
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

public protocol ImageAnalysisRepository: Sendable {
    /// 创建一次多图分析（至少 1 张图）
    @discardableResult
    func create(
        conversationID: String?,
        messageID: String?,
        attachmentIDs: [String],
        prompt: String,
        modelConfigID: String?,
        at millis: Int64
    ) async throws -> ImageAnalysisRecord

    func finish(id: String, result: String, status: String, at millis: Int64) async throws
    func analyses(messageID: String) async throws -> [ImageAnalysisRecord]
    func analyses(conversationID: String, limit: Int) async throws -> [ImageAnalysisRecord]
    func analysis(id: String) async throws -> ImageAnalysisRecord?
}

public enum MultimodalError: Error, Equatable, CustomStringConvertible {
    case notFound
    case emptyAttachments
    case emptyPrompt
    case invalidStatus(String)

    public var description: String {
        switch self {
        case .notFound: return "记录不存在"
        case .emptyAttachments: return "至少需要一张图片"
        case .emptyPrompt: return "分析指令不能为空"
        case .invalidStatus(let value): return "非法的分析状态：\(value)"
        }
    }
}
