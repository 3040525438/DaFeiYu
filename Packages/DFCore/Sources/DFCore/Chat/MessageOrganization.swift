import Foundation

// MARK: - 消息整理（D26）

public enum MessageOrganizationError: Error, Equatable, CustomStringConvertible {
    case notFound
    case deleted
    case emptyTag
    case tagTooLong(Int)

    public var description: String {
        switch self {
        case .notFound: return "消息不存在"
        case .deleted: return "消息已删除，不能整理"
        case .emptyTag: return "标签不能为空"
        case .tagTooLong(let max): return "标签最多 \(max) 个字符"
        }
    }
}

/// 标签使用统计（供"分类整理"界面按使用频次排序）。
public struct MessageTagCount: Sendable, Equatable, Identifiable {
    public var tag: String
    public var count: Int

    public var id: String { tag }

    public init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
    }
}

/// 消息列表过滤口径（收藏 / 重要 / 标签）。
public enum MessageFilter: Sendable, Hashable {
    case all
    case favorite
    case important
    case tagged(String)

    /// 标签过滤时的一级键；其余为 nil
    public var tag: String? {
        if case let .tagged(tag) = self { return tag }
        return nil
    }
}

/// 消息级整理：收藏、重要标记、分类标签。
///
/// 边界（D26）：
/// - 收藏与标签**不产生记忆**，也不写人格；它们只服务于消息检索与管理；
/// - 标签按"去首尾空白 + 去前导 # + 折叠连续空白"归一化，同一消息同一标签只保留一行；
/// - 所有批量操作在**单一写事务**内完成，避免部分成功的中间态。
public protocol MessageOrganizationRepository: Sendable {
    /// 标签长度上限（字符数）
    static var maxTagLength: Int { get }

    /// 重要标记：写 `is_important` 与 `important_at`。
    func setImportant(id: String, isImportant: Bool, at millis: Int64) async throws

    /// 批量收藏 / 取消收藏；返回**状态真正变化**的条数。
    @discardableResult
    func setFavoriteBatch(ids: [String], isFavorite: Bool, at millis: Int64) async throws -> Int

    /// 给多条消息打同一标签；已存在的跳过。返回**新增**的标签行数。
    @discardableResult
    func addTag(_ tag: String, to ids: [String], at millis: Int64) async throws -> Int

    /// 从多条消息移除同一标签；返回**删除**的标签行数。
    @discardableResult
    func removeTag(_ tag: String, from ids: [String]) async throws -> Int

    /// 某条消息的全部标签（按字母序，稳定输出）
    func tags(ofMessage id: String) async throws -> [String]

    /// 全部标签及使用次数：次数降序 → 标签升序
    func tagSummary() async throws -> [MessageTagCount]

    /// 按过滤口径取消息 id（最近创建优先）；只返回未软删消息。
    func messageIDs(filter: MessageFilter, limit: Int, offset: Int) async throws -> [String]
}

/// 消息标签规则（唯一事实源）。
public enum MessageTagRules {
    /// 标签长度上限（字符数）
    public static let maxLength = 24
}

public extension MessageOrganizationRepository {
    static var maxTagLength: Int { MessageTagRules.maxLength }

    /// 实例级访问标签长度上限。
    /// 协议静态成员不能稳定地通过协议元类型访问，界面层统一走这个实例属性。
    var tagLimit: Int { MessageTagRules.maxLength }
}
