import Foundation
import GRDB
import DFCore

/// 记忆召回：把"关键词命中"扩展成"能支撑回答的过去上下文"。
///
/// 背景：此前只用本轮用户原文做 bigram 检索，遇到"你还记得什么""我们以前聊过什么"
/// 这类泛问句时命中为空，提示词里一条记忆都没有，模型只能看见当前会话最近几轮，
/// 表现就是"只记得今晚"。
///
/// 因此这里补三条兜底（**只在命中为空或问句含回忆意图时启用**，避免污染日常闲聊）：
/// 1. 最近日记（带日期与结构化字段，模型知道"日记系统存在"）；
/// 2. 高显著度长期记忆（按 importance_score / confidence 排序）；
/// 3. 真实聊天片段：本会话更早的消息 + 其他会话的历史消息（带时间与角色）。
///
/// 所有条目都保留来源与时间，模型答不出来时应如实说"不确定"，不得编造。
public struct RecallContextBuilder: Sendable {
    /// 触发"兜底召回"的问句特征词。
    public static let recallCues: [String] = [
        "记得", "记不记得", "还记得", "记忆", "回忆", "想起",
        "以前", "之前", "上次", "上回", "那阵", "当时", "从前",
        "昨天", "前天", "上周", "上个月", "以前我们",
        "日记", "我们聊过", "你说过", "我说过", "发生过", "经历过",
        "一起去", "那一次", "那次"
    ]

    private let database: AppDatabase
    private let memories: MemoryRepository
    private let diary: DiaryRepository

    public init(database: AppDatabase, memories: MemoryRepository, diary: DiaryRepository) {
        self.database = database
        self.memories = memories
        self.diary = diary
    }

    /// 组装注入提示词的记忆行。
    ///
    /// - Parameters:
    ///   - query: 本轮用户原文
    ///   - currentConversationID: 当前会话（跨会话片段会排除它，避免与和上下文重复）
    ///   - limit: 最多返回多少行（提示词预算还会二次裁剪）
    public func recall(
        query: String,
        currentConversationID: String? = nil,
        now: Int64 = Clock.nowMillis(),
        limit: Int = 12,
        timeZoneIdentifier: String? = nil
    ) async -> [String] {
        let capped = min(max(limit, 6), 24)
        var lines: [String] = []
        var seen = Set<String>()

        func add(_ line: String) {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, lines.count < capped, !seen.contains(normalized) else { return }
            seen.insert(normalized)
            lines.append(normalized)
        }

        // 1. 关键词命中：最相关，永远排在最前
        let hits = (try? await memories.search(query: query, scope: nil, limit: capped)) ?? []
        for record in hits {
            add(Self.memoryLine(record))
        }

        // 1b. 导入的历史记忆
        // 导入的 AstrBot 记忆重要度统一是 0.5，按重要度排序永远排在最后，
        // 用户就会觉得"导入了几千条，她一条都不记得"。这里单独捞一批。
        if hits.isEmpty {
            for line in await importedMemoryLines(limit: 5) {
                add(line)
            }
        }

        // 2. 命中为空或明显在问过去 → 兜底召回
        let hasCue = Self.hasRecallCue(query)
        guard hits.isEmpty || hasCue else { return lines }

        let range = CurrentTimeContext.resolveDayRange(
            phrase: query,
            nowMillis: now,
            timeZoneIdentifier: timeZoneIdentifier
        )

        // 2a. 日记：优先按问句里的相对时间取，否则取最近一周
        for line in await diaryLines(range: range, now: now, timeZoneIdentifier: timeZoneIdentifier) {
            add(line)
        }

        // 2b. 高显著度长期记忆
        // 导入的 AstrBot 记忆动辄上百条，候选只取 40 条会让它们互相挤掉，
        // 表现就是"明明导入了却想不起来"。这里放宽候选并按 10 条注入。
        let important = (try? await memories.memories(
            scope: nil,
            layer: nil,
            includeArchived: false,
            limit: 200,
            offset: 0
        )) ?? []
        var importantAdded = 0
        for record in important {
            guard importantAdded < 10 else { break }
            let before = lines.count
            add(Self.memoryLine(record))
            if lines.count > before { importantAdded += 1 }
        }

        // 2c. 真实聊天片段：本会话更早 + 其他会话历史
        for line in await chatLines(
            currentConversationID: currentConversationID,
            now: now,
            timeZoneIdentifier: timeZoneIdentifier
        ) {
            add(line)
        }

        return lines
    }

    // MARK: - 判据

    /// 导入记忆单独取一批：按重要度排序它们会永远垫底，必须按来源直查。
    private func importedMemoryLines(limit: Int) async -> [String] {
        let timeZone = LocalDay.resolvedTimeZone(nil)
        let rows = (try? await database.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT title, content, created_at FROM memories
                 WHERE deleted_at IS NULL
                   AND archived_at IS NULL
                   AND source_kind = 'astrbot_import'
                 ORDER BY importance_score DESC, created_at DESC
                 LIMIT ?
                """,
                arguments: [min(max(limit, 1), 30)]
            )
        }) ?? []
        return rows.map { row in
            let title = String.fromDatabaseValue(row["title"]) ?? ""
            let content = String.fromDatabaseValue(row["content"]) ?? ""
            let at = Int64.fromDatabaseValue(row["created_at"]) ?? 0
            let day = LocalDay.dayKey(millis: at, timeZoneIdentifier: timeZone.identifier)
            let body = content.isEmpty ? title : content
            return "【导入记忆·\(day)】" + Self.clip(body, max: 110)
        }
    }

    public static func hasRecallCue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return recallCues.contains { trimmed.contains($0) }
    }

    // MARK: - 行格式化

    private static func memoryLine(_ record: MemoryRecord) -> String {
        let body = record.content.isEmpty ? record.title : record.content
        let tag = record.type.isEmpty ? "记忆" : record.type
        return "[\(tag)] \(clip(body, max: 120))"
    }

    private static func clip(_ text: String, max length: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > length else { return flattened }
        return String(flattened.prefix(length)) + "…"
    }

    private func diaryLines(
        range: CurrentTimeContext.DayRange?,
        now: Int64,
        timeZoneIdentifier: String?
    ) async -> [String] {
        let timeZone = LocalDay.resolvedTimeZone(timeZoneIdentifier)
        let endKey = range?.end ?? LocalDay.dayKey(millis: now, timeZoneIdentifier: timeZone.identifier)
        let startKey = range?.start
            ?? LocalDay.addingDays(-6, to: endKey, timeZoneIdentifier: timeZone.identifier)
            ?? endKey

        guard let entries = try? await diary.entries(from: startKey, to: endKey, limit: 5) else { return [] }
        return entries.map { entry in
            var parts: [String] = []
            if !entry.sharedExperience.isEmpty { parts.append("共同经历：\(Self.clip(entry.sharedExperience, max: 80))") }
            if !entry.observation.isEmpty { parts.append("观察：\(Self.clip(entry.observation, max: 60))") }
            if !entry.feeling.isEmpty { parts.append("感受：\(Self.clip(entry.feeling, max: 60))") }
            if parts.isEmpty { parts.append(Self.clip(entry.content, max: 120)) }
            return "【日记·\(entry.entryDate)】" + parts.joined(separator: "；")
        }
    }

    private func chatLines(
        currentConversationID: String?,
        now: Int64,
        timeZoneIdentifier: String?
    ) async -> [String] {
        let timeZone = LocalDay.resolvedTimeZone(timeZoneIdentifier)
        let todayStart = LocalDay.startOfDayMillis(millis: now, timeZoneIdentifier: timeZone.identifier) ?? now
        var lines: [String] = []

        // 本会话：今天之前的消息（"昨天聊过什么"）
        if let conversationID = currentConversationID {
            let rows = (try? await fetchMessages(
                conversationID: conversationID,
                beforeMillis: todayStart,
                limit: 10
            )) ?? []
            lines.append(contentsOf: rows.map { Self.chatLine($0, timeZone: timeZone) })
        }

        // 其他会话：优先取今天之前的历史，避免又把"今晚"重复塞一遍
        let historical = (try? await fetchMessages(
            conversationID: nil,
            excluding: currentConversationID,
            beforeMillis: todayStart,
            limit: 14
        )) ?? []
        if historical.isEmpty {
            let latest = (try? await fetchMessages(
                conversationID: nil,
                excluding: currentConversationID,
                beforeMillis: nil,
                limit: 6
            )) ?? []
            lines.append(contentsOf: latest.map { Self.chatLine($0, timeZone: timeZone) })
        } else {
            lines.append(contentsOf: historical.map { Self.chatLine($0, timeZone: timeZone) })
        }
        return lines
    }

    private struct ChatRow: Sendable {
        var role: String
        var text: String
        var createdAt: Int64
        var conversationTitle: String
    }

    private func fetchMessages(
        conversationID: String?,
        excluding: String? = nil,
        beforeMillis: Int64?,
        limit: Int
    ) async throws -> [ChatRow] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.role AS role, m.text AS text, m.created_at AS created_at,
                       c.title AS conversation_title
                FROM messages m
                JOIN conversations c ON c.id = m.conversation_id
                WHERE m.deleted_at IS NULL
                  AND m.revoked_at IS NULL
                  AND m.role IN ('user', 'assistant')
                  AND m.origin <> 'system'
                  AND length(trim(m.text)) > 0
                  AND (? IS NULL OR m.conversation_id = ?)
                  AND (? IS NULL OR m.conversation_id <> ?)
                  AND (? IS NULL OR m.created_at < ?)
                ORDER BY m.created_at DESC, m.rowid DESC
                LIMIT ?
                """,
                arguments: [
                    conversationID, conversationID,
                    excluding, excluding,
                    beforeMillis, beforeMillis,
                    min(max(limit, 1), 30)
                ]
            )
            return try rows.map { row in
                ChatRow(
                    role: try row.decode(String.self, forColumn: "role"),
                    text: try row.decode(String.self, forColumn: "text"),
                    createdAt: try row.decode(Int64.self, forColumn: "created_at"),
                    conversationTitle: try row.decode(String.self, forColumn: "conversation_title")
                )
            }
        }
    }

    private static func chatLine(_ row: ChatRow, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        let time = formatter.string(from: Date(timeIntervalSince1970: Double(row.createdAt) / 1000))
        let speaker = row.role == "user" ? "用户" : "我"
        return "【历史聊天·\(time)·\(speaker)·\(row.conversationTitle)】\(clip(row.text, max: 90))"
    }
}
