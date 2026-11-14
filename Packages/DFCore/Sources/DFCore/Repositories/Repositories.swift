import Foundation

public protocol ConversationRepository: Sendable {
    /// 确保存在 main 会话；不存在则创建。必须幂等。
    func ensureMainConversation(title: String) async throws -> Conversation
    func conversation(id: String) async throws -> Conversation?
    func touch(id: String, at millis: Int64) async throws
}

public protocol MessageRepository: Sendable {
    func insert(_ message: Message) async throws
    func update(_ message: Message) async throws
    func message(id: String) async throws -> Message?
    /// 按 created_at 升序返回最近 limit 条（返回结果内部为升序）
    func recentMessages(in conversationID: String, limit: Int) async throws -> [Message]
    func count(in conversationID: String) async throws -> Int
    /// 双键游标分页：`ORDER BY created_at DESC, rowid DESC` 取页，内存反转为升序返回。
    /// 游标取"上一页最旧一条"的 `(createdAt, rowid)`；软删消息不占返回条数、不产生游标。
    func page(in conversationID: String, before: PageCursor?, limit: Int) async throws -> MessagePage
    /// 组内消息，按 `created_at ASC, rowid ASC` 升序（含软删，由调用方决定是否过滤）
    func messages(inGroup groupID: String) async throws -> [Message]

    /// 定向正文更新：**只改 `text` 一列**，不得整行覆盖 `Message`。
    ///
    /// 安全条件（缺一不可）：
    /// - 记录存在；
    /// - 当前状态等于 `expectedStatus`（默认 `sending`）；
    /// - 未被软删。
    ///
    /// 用于"取消时保留已生成正文"等场景，避免把已定稿的 `status/sent_at/reply_to_id` 写回旧值。
    /// - Returns: `.updated` / `.statusMismatch` / `.notFound`
    /// - Throws: 仅数据库错误
    func updateAssistantText(
        _ text: String,
        for messageID: String,
        expectedStatus: MessageStatus = .sending
    ) async throws -> AssistantTextUpdateResult
}

/// 定向正文更新的结果，用于区分"写成功 / 状态不符 / 记录不存在"。
public enum AssistantTextUpdateResult: String, Sendable, Equatable {
    case updated
    case statusMismatch
    case notFound
}

/// 分页游标：`created_at` 主键 + `rowid` 次级键，保证同一毫秒内不重不漏。
public struct PageCursor: Codable, Hashable, Sendable {
    public var createdAt: Int64
    public var rowid: Int64

    public init(createdAt: Int64, rowid: Int64) {
        self.createdAt = createdAt
        self.rowid = rowid
    }
}

public struct MessagePage: Sendable, Equatable {
    /// 按时间升序返回
    public var items: [Message]
    /// `nil` 表示没有更早的消息
    public var nextCursor: PageCursor?
    public var hasMore: Bool

    public init(items: [Message] = [], nextCursor: PageCursor? = nil, hasMore: Bool = false) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

/// 开组请求（事务 A 的输入）
public struct OpenTurnRequest: Sendable {
    public var group: MessageGroup
    public var userMessage: Message
    public var assistantMessage: Message

    public init(group: MessageGroup, userMessage: Message, assistantMessage: Message) {
        self.group = group
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
    }
}

/// 定稿请求（事务 B 的输入）。四类写入在同一事务内完成。
public struct FinalizeTurnRequest: Sendable {
    public var groupID: String
    public var assistantMessageID: String
    /// 剥离尾注后的正文（解析失败时由调用方传入模型原始输出）
    public var text: String
    /// `.sent` / `.failed` / `.canceled`
    public var assistantStatus: MessageStatus
    public var sentAt: Int64?
    /// 唯一主引用；为空时跳过 `reply_to_id` 写入
    public var replyToID: String?
    public var references: [MessageReference]
    public var groupStatus: MessageGroupStatus
    public var closedAt: Int64

    public init(
        groupID: String,
        assistantMessageID: String,
        text: String,
        assistantStatus: MessageStatus,
        sentAt: Int64?,
        replyToID: String?,
        references: [MessageReference],
        groupStatus: MessageGroupStatus,
        closedAt: Int64
    ) {
        self.groupID = groupID
        self.assistantMessageID = assistantMessageID
        self.text = text
        self.assistantStatus = assistantStatus
        self.sentAt = sentAt
        self.replyToID = replyToID
        self.references = references
        self.groupStatus = groupStatus
        self.closedAt = closedAt
    }
}

/// 消息组仓储：负责事务 A（开组）、轮次/序号查询、关组、取消与陈旧消息修复。
/// 只读查询与"必须整体原子"的写入都收敛在实现内部，调用方不得自行拼装多步写。
public protocol MessageGroupRepository: Sendable {
    /// 事务 A：在同一写事务内计算 `turn_index`、插入组 / user / assistant（seq 0、1）。
    /// 唯一索引冲突时整体回滚，不产生半组。
    func openTurn(_ request: OpenTurnRequest) async throws -> MessageGroup
    func group(id: String) async throws -> MessageGroup?
    func openGroup(in conversationID: String) async throws -> MessageGroup?
    func maxTurnIndex(in conversationID: String) async throws -> Int?
    /// 组内最大 `seq_in_group`，**必须**来自不过滤 `deleted_at` 的 `SELECT max(seq_in_group)`。
    func maxSeq(inGroup groupID: String) async throws -> Int?
    /// 关闭组并写 `closed_at`；仅 `open` 组可关闭。
    func closeGroup(id: String, status: MessageGroupStatus, closedAt: Int64) async throws
    /// 取消 open 组：assistant → `canceled`（保留正文、不写 `sent_at`），组 → `aborted`。
    /// 终态组调用即抛错，不做静默降级。
    func cancelTurn(groupID: String, assistantMessageID: String, closedAt: Int64) async throws
    /// 崩溃恢复：把残留 `sending` 消息置 `failed`，其所属 `open` 组同步置 `failed` 并写 `closed_at`。
    /// 同一事务、幂等，重复执行安全。返回处理的 assistant 消息条数。
    @discardableResult
    func repairStaleSending(in conversationID: String) async throws -> Int
}

/// 定稿事务仓储：事务 B（四类写入原子完成）与补偿事务 C 的唯一拥有者。
public protocol MessageTurnRepository: Sendable {
    /// 事务 B：assistant 定稿 + `reply_to_id` + 引用批量写 + 组状态 + `closed_at`。
    /// 任一步失败整体回滚，不得留下"部分引用"或"已 sent 但组仍 open"。
    func finalizeTurn(_ request: FinalizeTurnRequest) async throws
    /// 事务 C：B 失败后的补偿——assistant 标 `failed`、组标 `failed`、写 `closed_at`（独立事务）。
    func failTurn(groupID: String, assistantMessageID: String, text: String?, closedAt: Int64) async throws
}

public protocol MessageReferenceRepository: Sendable {
    /// 批量写入（按 `(message_id, ref_message_id, relation)` 幂等）
    func insertBatch(_ references: [MessageReference]) async throws
    /// 按消息 id 批量取引用，一次往返
    func references(for messageIDs: [String]) async throws -> [MessageReference]
    /// 按 id 批量取被引用消息（含已软删，供 UI 判定"来源不可用"）
    func messages(ids: [String]) async throws -> [Message]
}

/// 注意：本协议刻意不提供 updateCore / deleteCore。
/// 核心人格只能通过"用户显式编辑"或"AstrBot 迁移"写入，
/// 由 PersonaRepository 的实现内部方法完成，AI 侧无法触达。
public protocol PersonaRepository: Sendable {
    func corePersona() async throws -> Persona?
    func coreSystemPrompt() async throws -> String?
    func outerItems() async throws -> [PersonaItem]
    func ensureCorePersona(name: String, systemPrompt: String) async throws -> Persona
}

public protocol ModelConfigRepository: Sendable {
    func all() async throws -> [ModelConfig]
    func defaultConfig() async throws -> ModelConfig?
    func config(id: String) async throws -> ModelConfig?
    func save(_ config: ModelConfig) async throws
    func delete(id: String) async throws
    func makeDefault(id: String) async throws
}

public protocol SettingsRepository: Sendable {
    func string(for key: String) async throws -> String?
    func set(_ value: String, for key: String) async throws
}

/// 密钥存储抽象。iOS 实现为 Keychain，其他平台实现直接抛错（防止误以为已安全保存）。
public protocol SecureStore: Sendable {
    func set(_ value: String, for key: String) throws
    func get(_ key: String) throws -> String?
    func delete(_ key: String) throws
}
