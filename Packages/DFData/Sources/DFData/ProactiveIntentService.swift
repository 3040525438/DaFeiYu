import Foundation
import GRDB
import DFCore

/// 主动意图生成与投递（W7-1 / N-20）。
///
/// 边界：
/// - 生成必须基于真实上下文（最近对话 / 候选记忆）；上下文为空时直接拒绝，不凭空编造；
/// - 模型输出必须是严格 JSON；证据逐字来自上下文，不在上下文中的证据一律丢弃；
/// - 投递前必须经过 `AutonomyService.evaluateSend` 的五重闸门，被拦截时只写 suppressed，不产生消息；
/// - 放行后才写入会话（`origin = proactive`）与 `proactive_messages`，并回填 `sent_at`；
/// - 本服务不负责系统通知展示，由 App 层按 `NotificationLevel` 投递。
public final class ProactiveIntentService: @unchecked Sendable {
    /// 生成上下文：调用方提供逐字片段，服务不做二次摘要
    public struct IntentContext: Sendable {
        public var conversationID: String
        public var topicID: String?
        public var localTimeText: String
        /// 最近几条真实对话（形如「用户：…」「大肥鱼：…」）
        public var recentTurns: [String]
        /// 候选记忆（来自 L1–L7 记忆层，可为空）
        public var candidateMemories: [String]
        /// 用户反馈提示（如"用户对 suggestion 表示不感兴趣"）
        public var feedbackHints: [String]

        public init(
            conversationID: String,
            topicID: String? = nil,
            localTimeText: String,
            recentTurns: [String],
            candidateMemories: [String] = [],
            feedbackHints: [String] = []
        ) {
            self.conversationID = conversationID
            self.topicID = topicID
            self.localTimeText = localTimeText
            self.recentTurns = recentTurns
            self.candidateMemories = candidateMemories
            self.feedbackHints = feedbackHints
        }
    }

    /// 生成结果：`candidateText` 只存在于内存，投递时再落库
    public struct Proposal: Sendable, Equatable {
        public var intent: ProactiveIntent
        public var candidateText: String?
        /// 服务端返回的 token 用量；未返回时为 nil（调用方据此记"估算"或"无法计量"）
        public var usage: Usage?

        public init(intent: ProactiveIntent, candidateText: String?, usage: Usage? = nil) {
            self.intent = intent
            self.candidateText = candidateText
            self.usage = usage
        }
    }

    public enum DispatchResult: Sendable, Equatable {
        case blocked(reason: String, runID: String)
        case delivered(
            messageID: String,
            proactiveMessageID: String,
            text: String,
            level: NotificationLevel
        )
    }

    /// 模型单次输出的最大候选长度，超出截断而不是拒绝
    public static let maxMessageLength = 500
    /// 证据条数上限
    public static let maxEvidenceCount = 8
    /// 单条证据长度上限
    public static let maxEvidenceLength = 200

    private let database: AppDatabase
    private let autonomy: AutonomyService
    private let proactive: ProactiveMessageService
    private let clock: AutonomyClock

    public init(
        database: AppDatabase,
        autonomy: AutonomyService,
        proactive: ProactiveMessageService,
        clock: AutonomyClock = .system
    ) {
        self.database = database
        self.autonomy = autonomy
        self.proactive = proactive
        self.clock = clock
    }

    // MARK: - 生成

    /// 调模型生成一次意图。模型判断不该说时返回 `skipped` 意图且 `candidateText == nil`。
    public func generate(
        trigger: ProactiveTrigger,
        context: IntentContext,
        provider: ChatModelProvider,
        model: String,
        maxTokens: Int = 320
    ) async throws -> Proposal {
        guard !context.recentTurns.isEmpty || !context.candidateMemories.isEmpty else {
            throw ProactiveIntentError.emptyContext
        }

        let request = ChatRequest(
            model: model,
            systemPrompt: Self.systemPrompt(for: trigger),
            messages: [ChatTurn(role: .user, text: Self.userPrompt(context: context))],
            temperature: 0.7,
            maxTokens: maxTokens
        )

        let result = try await StructuredChatRunner.run(provider: provider, request: request)
        let raw = result.text
        let usage = result.usage

        let parsed = try Self.parse(raw)
        let now = clock.now()

        let contextText = (context.recentTurns + context.candidateMemories + context.feedbackHints)
            .joined(separator: "\n")
        let evidence = Self.filterEvidence(parsed.evidence, against: contextText)

        var candidate: String?
        if parsed.shouldSend {
            let trimmed = parsed.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ProactiveIntentError.invalidOutput("should_send 为 true 但 message 为空")
            }
            candidate = String(trimmed.prefix(Self.maxMessageLength))
        }

        let status: ProactiveIntentStatus = parsed.shouldSend ? .planned : .skipped
        let intent = try await insert(
            conversationID: context.conversationID,
            topicID: context.topicID,
            trigger: trigger,
            status: status,
            reason: parsed.reason,
            evidence: evidence,
            at: now,
            decidedBy: "ai"
        )
        return Proposal(intent: intent, candidateText: candidate, usage: usage)
    }

    // MARK: - 投递

    /// 过五重闸门 → 放行才写会话与主动消息；被拦截时意图标记 suppressed。
    public func dispatch(
        intentID: String,
        text: String,
        todaySpentYuan: Double = 0,
        notificationsAuthorized: Bool = true,
        runTrigger: String = "background",
        budget: AutonomyBudgetContext? = nil,
        urgency: Double? = nil,
        speakReason: ReflectionSpeakReason = .none,
        cadence: CadenceSignals? = nil,
        urgencyThreshold: Double = ReflectionCadence.balancedThreshold
    ) async throws -> DispatchResult {
        guard let intent = try await intent(id: intentID) else {
            throw ProactiveIntentError.intentNotFound(intentID)
        }
        guard intent.status == .planned else {
            throw ProactiveIntentError.invalidState("当前为 \(intent.status.rawValue)，只有 planned 可投递")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProactiveIntentError.emptyMessage }

        let gate = try await autonomy.evaluateSend(
            trigger: intent.proactiveTrigger,
            todaySpentYuan: todaySpentYuan,
            notificationsAuthorized: notificationsAuthorized,
            runTrigger: runTrigger,
            budget: budget,
            urgency: urgency,
            speakReason: speakReason,
            cadence: cadence,
            urgencyThreshold: urgencyThreshold
        )

        guard gate.decision.allowed else {
            let reason = gate.decision.reason ?? "自主闸门拦截"
            try await mark(intentID: intent.id, status: .suppressed, suppressReason: reason, at: clock.now())
            return .blocked(reason: reason, runID: gate.runID)
        }

        try await database.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM conversations WHERE id = ?",
                arguments: [intent.conversationID]
            ) ?? 0
            guard count == 1 else {
                throw ProactiveIntentError.conversationMissing(intent.conversationID)
            }
        }

        let at = clock.now()
        let record = try await proactive.record(
            text: trimmed,
            triggerKind: intent.kind,
            plannedAt: at,
            notifyLevel: gate.notificationLevel,
            dedupeKey: "intent:\(intent.id)",
            expiresAt: intent.expiresAt,
            intentID: intent.id
        )

        let message = Message(
            conversationID: intent.conversationID,
            role: .assistant,
            kind: .text,
            text: trimmed,
            status: .sent,
            origin: .proactive,
            createdAt: at,
            sentAt: at
        )

        try await database.write { db in
            try message.insert(db)
            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [at, intent.conversationID]
            )
        }

        _ = try await proactive.markSent(id: record.id, messageID: message.id)
        try await mark(intentID: intent.id, status: .delivered, suppressReason: nil, at: at)

        return .delivered(
            messageID: message.id,
            proactiveMessageID: record.id,
            text: trimmed,
            level: gate.notificationLevel
        )
    }

    /// 放弃一个意图（如下一次生成前发现已过期）。
    public func abandon(intentID: String, reason: String) async throws {
        try await mark(intentID: intentID, status: .failed, suppressReason: reason, at: clock.now())
    }

    /// D47：新会话链路复用了同一次生成结果，内容已在新会话里投递，这里只把意图收尾。
    public func markHandledInNewConversation(intentID: String) async throws {
        try await mark(intentID: intentID, status: .delivered, suppressReason: nil, at: clock.now())
    }

    /// D47：新会话决策为复用 / 跳过时，把意图标记为已抑制并留下原因。
    public func markSuppressedInNewConversation(intentID: String, reason: String) async throws {
        try await mark(intentID: intentID, status: .suppressed, suppressReason: reason, at: clock.now())
    }

    // MARK: - 读取

    public func intent(id: String) async throws -> ProactiveIntent? {
        try await database.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversation_intents WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return Self.decode(row)
        }
    }

    public func recentIntents(limit: Int = 20) async throws -> [ProactiveIntent] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_intents
                 ORDER BY created_at DESC LIMIT ?
                """,
                arguments: [max(1, limit)]
            )
            return rows.map(Self.decode)
        }
    }

    // MARK: - 写入

    private func insert(
        conversationID: String,
        topicID: String?,
        trigger: ProactiveTrigger,
        status: ProactiveIntentStatus,
        reason: String,
        evidence: [String],
        at: Int64,
        decidedBy: String
    ) async throws -> ProactiveIntent {
        let id = UUID().uuidString
        let evidenceJSON = Self.encodeEvidence(evidence)
        let reasonText = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))

        try await database.write { db in
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM conversations WHERE id = ?",
                arguments: [conversationID]
            ) ?? 0
            guard exists == 1 else {
                throw ProactiveIntentError.conversationMissing(conversationID)
            }
            try db.execute(
                sql: """
                INSERT INTO conversation_intents
                    (id, conversation_id, topic_id, group_id, kind, status, trigger, reason,
                     evidence_json, confidence, priority, planned_at, expires_at, suppress_reason,
                     decided_by, created_at, resolved_at)
                VALUES (?, ?, ?, NULL, ?, ?, 'autonomy', ?, ?, ?, 3, ?, NULL, NULL, ?, ?, ?)
                """,
                arguments: [
                    id, conversationID, topicID, trigger.rawValue, status.rawValue,
                    reasonText, evidenceJSON, 0.5, at, decidedBy, at,
                    status == .planned ? nil : at
                ]
            )
        }

        guard let created = try await intent(id: id) else {
            throw ProactiveIntentError.intentNotFound(id)
        }
        return created
    }

    private func mark(
        intentID: String,
        status: ProactiveIntentStatus,
        suppressReason: String?,
        at: Int64
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                UPDATE conversation_intents
                   SET status = ?, suppress_reason = ?, decided_by = 'system', resolved_at = ?
                 WHERE id = ?
                """,
                arguments: [status.rawValue, suppressReason, at, intentID]
            )
        }
    }

    // MARK: - 解析

    struct RawIntent: Decodable {
        var shouldSend: Bool
        var reason: String
        var evidence: [String]
        var message: String

        private enum CodingKeys: String, CodingKey {
            case shouldSend = "should_send"
            case reason
            case evidence
            case message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shouldSend = try container.decode(Bool.self, forKey: .shouldSend)
            reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
            evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
            message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        }
    }

    /// 容忍 ```json 代码围栏与前后说明文字，只取最外层 JSON 对象。
    static func parse(_ raw: String) throws -> RawIntent {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            throw ProactiveIntentError.invalidOutput("未找到 JSON 对象")
        }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8) else {
            throw ProactiveIntentError.invalidOutput("编码失败")
        }
        do {
            return try JSONDecoder().decode(RawIntent.self, from: data)
        } catch {
            throw ProactiveIntentError.invalidOutput("JSON 结构不符：\(error.localizedDescription)")
        }
    }

    /// 证据必须逐字出现在上下文中，否则丢弃（不编造引用）。
    static func filterEvidence(_ evidence: [String], against context: String) -> [String] {
        var result: [String] = []
        for item in evidence {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, context.contains(trimmed) else { continue }
            let clipped = String(trimmed.prefix(maxEvidenceLength))
            if !result.contains(clipped) {
                result.append(clipped)
            }
            if result.count >= maxEvidenceCount { break }
        }
        return result
    }

    static func encodeEvidence(_ evidence: [String]) -> String {
        guard let data = try? JSONEncoder().encode(evidence),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    // MARK: - 提示词

    static let systemPrompt = """
    你是「大肥鱼」，与用户长期相处。现在要做一次"是否主动说点什么"的判断。
    必须只输出一个 JSON 对象，不要输出任何解释或代码围栏：
    {"should_send": true 或 false, "reason": "一句话原因", "evidence": ["逐字引用上下文中的片段"], "message": "要对用户说的话"}
    规则：
    1. evidence 必须逐字出自给定上下文；没有证据就不要编造，宁可不发。
    2. should_send 为 false 时 message 必须为空字符串。
    3. message 用第一人称、口语、简短（不超过 120 字），不要提及"上下文/模型/系统"。
    4. 不索取隐私、不制造焦虑、不假装记得未提供的事情。
    """

    /// D47：主动开新会话时 `reason` 复用为"话题名"，因此单独一套提示词。
    static let newConversationSystemPrompt = """
    你是「大肥鱼」，与用户长期相处。现在要判断"是否值得为这件事单独开一个新会话"。
    必须只输出一个 JSON 对象，不要输出任何解释或代码围栏：
    {"should_send": true 或 false, "reason": "3 到 12 个字的话题名", "evidence": ["逐字引用上下文中的片段"], "message": "开场的第一句话"}
    规则：
    1. evidence 必须逐字出自给定上下文；没有证据就不要编造，宁可不发。
    2. 只有出现了"现有连续对话装不下"的新话题时，should_send 才为 true；否则为 false，message 为空字符串。
    3. reason 会被直接当作会话标题：不要标点、不要引号、不要"关于/聊聊"之类的空话。
    4. message 用第一人称、口语、简短（不超过 120 字），不要提及"上下文/模型/系统"。
    5. 不索取隐私、不制造焦虑、不假装记得未提供的事情。
    """

    static func systemPrompt(for trigger: ProactiveTrigger) -> String {
        trigger == .newConversation ? newConversationSystemPrompt : systemPrompt
    }

    static func userPrompt(context: IntentContext) -> String {
        var lines: [String] = []
        lines.append("当前时间：\(context.localTimeText)")
        lines.append("最近对话：")
        lines.append(contentsOf: context.recentTurns.isEmpty ? ["（无）"] : context.recentTurns)
        lines.append("候选记忆：")
        lines.append(contentsOf: context.candidateMemories.isEmpty ? ["（无）"] : context.candidateMemories)
        if !context.feedbackHints.isEmpty {
            lines.append("用户反馈：")
            lines.append(contentsOf: context.feedbackHints)
        }
        lines.append("请判断此刻是否适合主动说点什么。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 解码

    static func decode(_ row: Row) -> ProactiveIntent {
        ProactiveIntent(
            id: (try? row.decode(String.self, forColumn: "id")) ?? "",
            conversationID: (try? row.decode(String.self, forColumn: "conversation_id")) ?? "",
            topicID: String.fromDatabaseValue(row["topic_id"]),
            groupID: String.fromDatabaseValue(row["group_id"]),
            kind: (try? row.decode(String.self, forColumn: "kind")) ?? ProactiveTrigger.message.rawValue,
            status: ProactiveIntentStatus(
                rawValue: (try? row.decode(String.self, forColumn: "status")) ?? ""
            ) ?? .planned,
            trigger: (try? row.decode(String.self, forColumn: "trigger")) ?? "autonomy",
            reason: (try? row.decode(String.self, forColumn: "reason")) ?? "",
            evidenceJSON: (try? row.decode(String.self, forColumn: "evidence_json")) ?? "[]",
            confidence: (try? row.decode(Double.self, forColumn: "confidence")) ?? 0.5,
            priority: (try? row.decode(Int.self, forColumn: "priority")) ?? 3,
            plannedAt: (try? row.decode(Int64.self, forColumn: "planned_at")) ?? 0,
            expiresAt: Int64.fromDatabaseValue(row["expires_at"]),
            suppressReason: String.fromDatabaseValue(row["suppress_reason"]),
            decidedBy: String.fromDatabaseValue(row["decided_by"]),
            createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0,
            resolvedAt: Int64.fromDatabaseValue(row["resolved_at"])
        )
    }
}
