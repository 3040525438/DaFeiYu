import Foundation
import GRDB
import DFCore

/// D47：AI 主动创建会话。
///
/// 边界：
/// - 是否新开由 `NewConversationPolicy` 决定（纯逻辑，可测）；
/// - 同主题已有会话 → **复用**，不新建，避免把一段对话拆成多个会话；
/// - 新建的会话 `kind = "proactive"`，与现有会话体系完全兼容（列表、检索、归档都能识别）；
/// - 每次判断都写一条 `autonomy_runs`：新建记 done，复用 / 跳过记 skipped，便于回溯；
/// - 本服务不发送通知，由 App 层按 `NotificationLevel` 投递。
public final class ProactiveConversationService: @unchecked Sendable {
    /// 主动会话的 `kind` 取值
    public static let conversationKind = "proactive"

    public enum Outcome: Sendable, Equatable {
        case created(conversationID: String, title: String, runID: String)
        case reused(conversationID: String, title: String, runID: String)
        case skipped(reason: String, runID: String)

        /// 是否产生了一个可以让用户进去看的会话
        public var hasConversation: Bool {
            switch self {
            case .created, .reused: return true
            case .skipped: return false
            }
        }

        public var conversationID: String? {
            switch self {
            case .created(let id, _, _), .reused(let id, _, _): return id
            case .skipped: return nil
            }
        }

        public var title: String? {
            switch self {
            case .created(_, let title, _), .reused(_, let title, _): return title
            case .skipped: return nil
            }
        }
    }

    private let database: AppDatabase
    private let conversations: ConversationAdminRepository
    private let autonomy: AutonomyService
    private let clock: AutonomyClock

    public init(
        database: AppDatabase,
        conversations: ConversationAdminRepository,
        autonomy: AutonomyService,
        clock: AutonomyClock = .system
    ) {
        self.database = database
        self.conversations = conversations
        self.autonomy = autonomy
        self.clock = clock
    }

    /// 判断并按结论执行。
    ///
    /// - Parameters:
    ///   - candidate: 候选新会话（标题草稿、话题锚点、去重键）
    ///   - notificationsAuthorized: 是否已获得通知授权（会影响闸门的打扰类判断）
    ///   - budget: D10 预算上下文
    public func evaluateAndCreate(
        candidate: NewConversationCandidate,
        notificationsAuthorized: Bool = true,
        trigger: String = "background",
        budget: AutonomyBudgetContext? = nil
    ) async throws -> Outcome {
        let now = clock.now()

        // 闸门：新会话属于会打扰用户的主动行为，必须先过五重检查
        let gate = try await autonomy.evaluateSend(
            trigger: .newConversation,
            notificationsAuthorized: notificationsAuthorized,
            runTrigger: trigger,
            budget: budget
        )
        guard gate.decision.allowed else {
            let reason = gate.decision.reason ?? "自主闸门拦截"
            return .skipped(reason: reason, runID: gate.runID)
        }

        let stats = try await stats(dayStart: clock.dayStart(now))
        let existing = (try? await conversations.list(.all)) ?? []
        let briefs = existing.map {
            ExistingConversationBrief(
                id: $0.id,
                title: $0.title,
                createdAt: $0.createdAt,
                isArchived: $0.archivedAt != nil
            )
        }

        let decision = NewConversationPolicy.decide(
            candidate: candidate,
            existing: briefs,
            lastCreatedAt: stats.lastCreatedAt,
            createdToday: stats.createdToday,
            nowMillis: now,
            usedDedupeKeys: stats.usedDedupeKeys
        )

        switch decision {
        case let .create(title, reason):
            let summary = try await conversations.create(
                title: title,
                kind: Self.conversationKind,
                at: now
            )
            let runID = try await autonomy.recordRun(
                taskID: nil,
                kind: ProactiveTrigger.newConversation.rawValue,
                trigger: trigger,
                status: .done,
                decision: "create",
                blockReason: nil,
                detailJSON: Self.detailJSON(
                    title: title,
                    reason: reason,
                    dedupeKey: candidate.dedupeKey,
                    conversationID: summary.id
                )
            )
            return .created(conversationID: summary.id, title: title, runID: runID)

        case let .reuse(conversationID, title, reason):
            let runID = try await autonomy.recordRun(
                taskID: nil,
                kind: ProactiveTrigger.newConversation.rawValue,
                trigger: trigger,
                status: .skipped,
                decision: "reuse",
                blockReason: nil,
                detailJSON: Self.detailJSON(
                    title: title,
                    reason: reason,
                    dedupeKey: candidate.dedupeKey,
                    conversationID: conversationID
                )
            )
            return .reused(conversationID: conversationID, title: title, runID: runID)

        case let .skip(reason):
            let runID = try await autonomy.recordRun(
                taskID: nil,
                kind: ProactiveTrigger.newConversation.rawValue,
                trigger: trigger,
                status: .skipped,
                decision: "skip",
                blockReason: reason,
                detailJSON: Self.detailJSON(
                    title: candidate.titleDraft,
                    reason: reason,
                    dedupeKey: candidate.dedupeKey,
                    conversationID: nil
                )
            )
            return .skipped(reason: reason, runID: runID)
        }
    }

    // MARK: - 统计

    struct Stats: Sendable, Equatable {
        var createdToday: Int
        var lastCreatedAt: Int64?
        var usedDedupeKeys: Set<String>
    }

    /// 读取三个决策输入：今日已建数、上次创建时间、已用去重键。
    ///
    /// 去重键存放在 `autonomy_runs.detail_json` 里（不新增迁移）：
    /// 只查 `new_conversation` 且 `decision = 'create'` 的最近 200 条记录。
    func stats(dayStart: Int64) async throws -> Stats {
        try await database.dbQueue.read { db in
            let createdToday = try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM conversations
                 WHERE kind = ? AND created_at >= ?
                """,
                arguments: [Self.conversationKind, dayStart]
            ) ?? 0
            let lastCreatedAt = try Int64.fetchOne(
                db,
                sql: "SELECT max(created_at) FROM conversations WHERE kind = ?",
                arguments: [Self.conversationKind]
            )
            let rows = try String.fetchAll(
                db,
                sql: """
                SELECT detail_json FROM autonomy_runs
                 WHERE kind = ? AND decision = 'create'
                 ORDER BY started_at DESC LIMIT 200
                """,
                arguments: [ProactiveTrigger.newConversation.rawValue]
            )
            var keys = Set<String>()
            for json in rows {
                if let key = Self.dedupeKey(fromDetailJSON: json), !key.isEmpty {
                    keys.insert(key)
                }
            }
            return Stats(
                createdToday: createdToday,
                lastCreatedAt: lastCreatedAt,
                usedDedupeKeys: keys
            )
        }
    }

    // MARK: - JSON

    static func detailJSON(
        title: String,
        reason: String,
        dedupeKey: String,
        conversationID: String?
    ) -> String {
        let payload: [String: Any] = [
            "title": title,
            "reason": reason,
            "dedupe_key": dedupeKey,
            "conversation_id": conversationID ?? ""
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 从 `detail_json` 取出 `dedupe_key`；解析失败返回 nil，不抛错。
    static func dedupeKey(fromDetailJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let key = dict["dedupe_key"] as? String else {
            return nil
        }
        return key
    }
}
