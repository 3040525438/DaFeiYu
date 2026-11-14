import Foundation

// MARK: - 每日日记（W6-7）

/// 一天一篇。软删后允许重建同一天。
public struct DiaryEntry: Sendable, Equatable, Identifiable {
    public var id: String
    /// `yyyy-MM-dd`（本地日历日，由调用方按用户时区生成）
    public var entryDate: String
    public var title: String
    public var content: String
    public var moodCode: String?
    /// manual / auto / migrated
    public var source: String
    public var generatedBy: String?
    public var isUserEdited: Bool
    /// 日记沉淀成的长期记忆
    public var memoryID: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public var isDeleted: Bool { deletedAt != nil }
}

/// 全量版本快照：任何一次编辑都留档，不可覆盖。
public struct DiaryVersion: Sendable, Equatable, Identifiable {
    public var id: String
    public var diaryID: String
    public var version: Int
    public var title: String
    public var content: String
    public var changeReason: String
    /// user / ai / migration
    public var changedBy: String
    public var createdAt: Int64
}

public enum DiaryError: Error, Equatable, CustomStringConvertible {
    case notFound
    case emptyContent
    case invalidDate(String)
    case invalidEditor(String)

    public var description: String {
        switch self {
        case .notFound: return "日记不存在"
        case .emptyContent: return "日记内容不能为空"
        case .invalidDate(let value): return "日期格式必须为 yyyy-MM-dd：\(value)"
        case .invalidEditor(let value): return "非法的编辑者：\(value)"
        }
    }
}

/// 日记写入请求。
public struct DiaryUpsert: Sendable, Equatable {
    public var entryDate: String
    public var title: String
    public var content: String
    public var moodCode: String?
    public var source: String
    public var generatedBy: String?
    public var isUserEdited: Bool
    public var memoryID: String?
    /// 本次变更原因（写入版本表）
    public var changeReason: String
    /// user / ai / migration
    public var changedBy: String

    public init(
        entryDate: String,
        title: String = "",
        content: String,
        moodCode: String? = nil,
        source: String = "manual",
        generatedBy: String? = nil,
        isUserEdited: Bool = false,
        memoryID: String? = nil,
        changeReason: String = "",
        changedBy: String = "user"
    ) {
        self.entryDate = entryDate
        self.title = title
        self.content = content
        self.moodCode = moodCode
        self.source = source
        self.generatedBy = generatedBy
        self.isUserEdited = isUserEdited
        self.memoryID = memoryID
        self.changeReason = changeReason
        self.changedBy = changedBy
    }
}

public protocol DiaryRepository: Sendable {
    /// 写入当天日记：无则新建（版本 1），有则更新并追加一版全量快照。
    /// 内容为空白时抛 `emptyContent`；`changedBy` 只接受 user / ai / migration。
    @discardableResult
    func upsert(_ request: DiaryUpsert, at millis: Int64) async throws -> DiaryEntry

    func entry(id: String) async throws -> DiaryEntry?
    /// 未软删的当天日记
    func entry(date: String) async throws -> DiaryEntry?
    /// 日期区间（含两端）内的日记，按日期倒序
    func entries(from startDate: String, to endDate: String, limit: Int) async throws -> [DiaryEntry]
    func versions(diaryID: String) async throws -> [DiaryVersion]

    func softDelete(id: String, at millis: Int64) async throws
    /// 关键词检索日记正文，返回日记 id（按相关度升序）
    func search(query: String, limit: Int) async throws -> [String]
    /// 重建日记全文索引，返回索引条数
    @discardableResult
    func rebuildIndex() async throws -> Int
}
