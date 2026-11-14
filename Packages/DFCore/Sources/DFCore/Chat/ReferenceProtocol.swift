import Foundation

/// 引用协议的 system 片段与校验规则（纯逻辑，不依赖具体模型）。
///
/// 职责边界：
/// - 本类型只做**白名单、存在性、会话归属、数量**的判定；
/// - 不做数据库查询——存在性与归属由调用方以普通字典 / 集合传入（A2 负责填充）；
/// - 不依赖 tool calling，任何文本模型都能用；将来切换为工具调用时以此处为切换点。
public enum ReferenceProtocol {
    /// 追加到 system prompt 末尾的可选协议说明
    public static let systemFragment = """
    【引用协议（可选）】
    如果你这句话确实在回应或延续之前某条消息，可以在回复的最后单独一行输出：
    \(StreamingReferenceParser.tagOpen)["<message_id>"]>>
    - 只在真的有指向时输出；不需要引用时不要输出这一行。
    - 最多 \(StreamingReferenceParser.maxRefs) 条，按重要程度排序。
    - 绝不能编造 id，只能使用上文出现过的消息 id。
    """

    public struct ValidationInput: Sendable {
        /// 模型输出的原始引用 id（可能有重复、未知、跨会话）
        public var citations: [String]
        /// 本轮送入模型的消息 id 集合（白名单）
        public var allowed: Set<String>
        /// 库中存在且未软删的消息 → 所属会话 id
        public var existingConversationMap: [String: String]
        /// 已软删的消息 id（用于区分"不存在"与"已删除"）
        public var deletedIDs: Set<String>
        /// 当前 assistant 消息所属会话
        public var conversationID: String

        public init(
            citations: [String],
            allowed: Set<String>,
            existingConversationMap: [String: String],
            deletedIDs: Set<String> = [],
            conversationID: String
        ) {
            self.citations = citations
            self.allowed = allowed
            self.existingConversationMap = existingConversationMap
            self.deletedIDs = deletedIDs
            self.conversationID = conversationID
        }
    }

    public struct ValidationResult: Sendable, Equatable {
        public var kept: [String]
        public var droppedUnknown: Int
        public var droppedCrossConversation: Int
        public var droppedDeleted: Int
        public var droppedOverLimit: Int

        public init(
            kept: [String] = [],
            droppedUnknown: Int = 0,
            droppedCrossConversation: Int = 0,
            droppedDeleted: Int = 0,
            droppedOverLimit: Int = 0
        ) {
            self.kept = kept
            self.droppedUnknown = droppedUnknown
            self.droppedCrossConversation = droppedCrossConversation
            self.droppedDeleted = droppedDeleted
            self.droppedOverLimit = droppedOverLimit
        }
    }

    /// 校验引用，顺序为：去重 → 数量上限 → 已删 → 存在性 → 会话归属 → 白名单。
    /// 任何一类不通过都只丢弃该条，不抛错、不影响已生成的回复。
    public static func validate(_ input: ValidationInput) -> ValidationResult {
        var result = ValidationResult()

        var seen = Set<String>()
        var unique: [String] = []
        for id in input.citations where seen.insert(id).inserted {
            unique.append(id)
        }

        var candidates = unique
        if candidates.count > StreamingReferenceParser.maxRefs {
            result.droppedOverLimit = candidates.count - StreamingReferenceParser.maxRefs
            candidates = Array(candidates.prefix(StreamingReferenceParser.maxRefs))
        }

        for id in candidates {
            if input.deletedIDs.contains(id) {
                result.droppedDeleted += 1
                continue
            }
            guard let conversation = input.existingConversationMap[id] else {
                result.droppedUnknown += 1
                continue
            }
            guard conversation == input.conversationID else {
                result.droppedCrossConversation += 1
                continue
            }
            guard input.allowed.contains(id) else {
                result.droppedUnknown += 1
                continue
            }
            result.kept.append(id)
        }
        return result
    }
}
