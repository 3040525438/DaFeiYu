import Foundation
import GRDB
import DFCore

/// 每日日记的自动生成与补偿（W6 / D34 / D72）。
///
/// 背景：此后台任务只负责"按策略把该写的日子补上"，不假装能在 23:00 准点执行——
/// iOS 的后台唤醒时机由系统决定，精确时间保证不了（见 `DiarySchedulePolicy` 注释）。
///
/// 硬约束：
/// - 只依据当天**真实存在**的消息生成，消息不足直接跳过，绝不编造经历；
/// - 模型输出必须是严格 JSON，解析失败一律不写库（宁可没有日记，也不写假日记）；
/// - 关系变化只作为观察写入，`relationship_change_confirmed` 恒为 false；
/// - 用户手写或编辑过的日记不覆盖；
/// - 核心人格只作为语气参考，不允许被日记改写。
public struct DiaryAutoService: Sendable {
    /// 生成结果状态
    public enum Status: String, Sendable, Equatable {
        /// 新建了当天的自动日记
        case generated
        /// 覆盖了此前由自动生成的同一天日记
        case updated
        /// 当天没有足够真实内容，未生成
        case skippedNoContent
        /// 当天已有用户手写/编辑过的日记，不覆盖
        case skippedUserEdited
        /// 模型输出无法解析或缺少必要字段
        case failed
    }

    public struct Report: Sendable, Equatable {
        public var dayKey: String
        public var status: Status
        public var entryID: String?
        public var messageCount: Int
        /// 日记沉淀出的记忆 ID（未开启沉淀时为空）
        public var distilledMemoryIDs: [String]
        /// 人类可读的说明，用于界面与诊断
        public var note: String

        public init(
            dayKey: String,
            status: Status,
            entryID: String? = nil,
            messageCount: Int = 0,
            distilledMemoryIDs: [String] = [],
            note: String = ""
        ) {
            self.dayKey = dayKey
            self.status = status
            self.entryID = entryID
            self.messageCount = messageCount
            self.distilledMemoryIDs = distilledMemoryIDs
            self.note = note
        }
    }

    /// 一条参与日记生成的原始消息
    public struct SourceMessage: Sendable, Equatable {
        public var role: String
        public var text: String
        public var createdAt: Int64
        public var conversationTitle: String
    }

    /// 参与生成的最小消息条数：至少要有一来一回
    public static let minimumMessageCount = 2
    /// 送进提示词的最大字符数（超出后保留最早与最近两段）
    public static let maximumTranscriptCharacters = 6000

    private let database: AppDatabase
    private let diary: DiaryRepository
    private let distiller: DiaryMemoryService?
    private let now: @Sendable () -> Int64

    public init(
        database: AppDatabase,
        diary: DiaryRepository,
        distiller: DiaryMemoryService? = nil,
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.database = database
        self.diary = diary
        self.distiller = distiller
        self.now = now
    }

    // MARK: - 生成

    /// 为指定日期生成日记。`persona` 只影响语气，不参与事实。
    public func generate(
        dayKey: String,
        timeZoneIdentifier: String? = nil,
        provider: ChatModelProvider,
        model: String,
        persona: String = "",
        maxTokens: Int = 900,
        distill: Bool = false
    ) async throws -> Report {
        let timeZone = LocalDay.resolvedTimeZone(timeZoneIdentifier)
        let messages = try await messages(on: dayKey, timeZoneIdentifier: timeZone.identifier)

        guard messages.count >= Self.minimumMessageCount,
              messages.contains(where: { $0.role == "user" && $0.text.count >= 2 }) else {
            return Report(
                dayKey: dayKey,
                status: .skippedNoContent,
                messageCount: messages.count,
                note: "当天有效聊天不足 \(Self.minimumMessageCount) 条，不生成日记"
            )
        }

        // 用户手写 / 编辑过的日记一律不覆盖
        if let existing = try await diary.entry(date: dayKey),
           existing.isUserEdited || existing.source != "auto" {
            return Report(
                dayKey: dayKey,
                status: .skippedUserEdited,
                entryID: existing.id,
                messageCount: messages.count,
                note: "当天已有用户手写的日记，不覆盖"
            )
        }

        let transcript = Self.transcript(messages, timeZone: timeZone, limit: Self.maximumTranscriptCharacters)
        let request = ChatRequest(
            model: model,
            systemPrompt: Self.systemPrompt,
            messages: [
                ChatTurn(
                    role: .user,
                    text: Self.userPrompt(dayKey: dayKey, transcript: transcript, persona: persona)
                )
            ],
            temperature: 0.5,
            maxTokens: maxTokens
        )

        var raw = ""
        for try await delta in provider.stream(request) {
            if Task.isCancelled { throw DFError.cancelled }
            if case .text(let piece) = delta { raw += piece }
        }

        let draft: Draft
        do {
            draft = try Self.parse(raw)
        } catch {
            return Report(
                dayKey: dayKey,
                status: .failed,
                messageCount: messages.count,
                note: "模型输出不是可用的日记 JSON：\(error)"
            )
        }

        if draft.skip {
            return Report(
                dayKey: dayKey,
                status: .skippedNoContent,
                messageCount: messages.count,
                note: "模型判断当天没有值得写入日记的内容"
            )
        }

        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return Report(
                dayKey: dayKey,
                status: .failed,
                messageCount: messages.count,
                note: "模型输出的日记正文为空"
            )
        }

        let existed = try await diary.entry(date: dayKey) != nil
        let entry = try await diary.upsert(
            DiaryUpsert(
                entryDate: dayKey,
                title: draft.title,
                content: content,
                moodCode: Self.normalizeMood(draft.mood),
                source: "auto",
                generatedBy: model,
                isUserEdited: false,
                memoryID: nil,
                sharedExperience: draft.sharedExperience,
                observation: draft.observation,
                feeling: draft.feeling,
                relationshipChange: draft.relationshipChange,
                // 关系变化必须由用户确认，自动生成永远不置 true
                relationshipChangeConfirmed: false,
                changeReason: existed ? "自动重写当天日记" : "每日自动生成",
                changedBy: "ai"
            ),
            at: now()
        )

        var distilled: [String] = []
        var note = existed ? "已覆盖此前的自动日记" : "已生成当天日记"
        if distill, let distiller {
            do {
                let outcome = try await distiller.distill(entryID: entry.id, at: now())
                if case let .distilled(memoryIDs, proposalIDs) = outcome {
                    distilled = memoryIDs
                    note += "，沉淀 \(memoryIDs.count) 条记忆、\(proposalIDs.count) 条待确认提案"
                }
            } catch {
                // 沉淀失败不影响日记本身，只记录原因
                note += "；记忆沉淀失败：\(error.localizedDescription)"
            }
        }

        return Report(
            dayKey: dayKey,
            status: existed ? .updated : .generated,
            entryID: entry.id,
            messageCount: messages.count,
            distilledMemoryIDs: distilled,
            note: note
        )
    }

    /// 启动 / 回到前台 / 后台唤醒时调用：把"该写但没写"的日子补上。
    ///
    /// - 已经存在日记（含手写）的日期不再处理；
    /// - 今天只有在 23:00 之后才列入；
    /// - 单日失败不影响其他日期，继续往下跑。
    public func runCompensation(
        lookbackDays: Int = DiarySchedulePolicy.defaultLookbackDays,
        timeZoneIdentifier: String? = nil,
        distill: Bool = false,
        generate: (String) async throws -> Report
    ) async -> [Report] {
        let timeZone = LocalDay.resolvedTimeZone(timeZoneIdentifier)
        let timestamp = now()
        let today = LocalDay.dayKey(millis: timestamp, timeZoneIdentifier: timeZone.identifier)
        let start = LocalDay.addingDays(-max(lookbackDays, 0), to: today, timeZoneIdentifier: timeZone.identifier) ?? today

        let existing = (try? await diary.entries(from: start, to: today, limit: 60)) ?? []
        let generatedDays = Set(existing.map(\.entryDate))
        let pending = DiarySchedulePolicy.pendingDays(
            nowMillis: timestamp,
            generatedDays: generatedDays,
            lookbackDays: lookbackDays,
            timeZoneIdentifier: timeZone.identifier
        )
        guard !pending.isEmpty else { return [] }

        var reports: [Report] = []
        for day in pending {
            do {
                reports.append(try await generate(day))
            } catch {
                reports.append(
                    Report(
                        dayKey: day,
                        status: .failed,
                        note: "生成失败：\(error.localizedDescription)"
                    )
                )
            }
        }
        return reports
    }

    // MARK: - 读取当天消息

    public func messages(
        on dayKey: String,
        timeZoneIdentifier: String? = nil
    ) async throws -> [SourceMessage] {
        guard let start = LocalDay.millis(dayKey: dayKey, timeZoneIdentifier: timeZoneIdentifier) else {
            return []
        }
        let timeZone = LocalDay.resolvedTimeZone(timeZoneIdentifier)
        let end = LocalDay.addingDays(1, to: dayKey, timeZoneIdentifier: timeZone.identifier)
            .flatMap { LocalDay.millis(dayKey: $0, timeZoneIdentifier: timeZone.identifier) }
            ?? (start + 24 * 60 * 60 * 1000)

        return try await database.dbQueue.read { db in
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
                  AND m.created_at >= ? AND m.created_at < ?
                  AND length(trim(m.text)) > 0
                ORDER BY m.created_at ASC, m.rowid ASC
                LIMIT 800
                """,
                arguments: [start, end]
            )
            return try rows.map { row in
                SourceMessage(
                    role: try row.decode(String.self, forColumn: "role"),
                    text: try row.decode(String.self, forColumn: "text"),
                    createdAt: try row.decode(Int64.self, forColumn: "created_at"),
                    conversationTitle: try row.decode(String.self, forColumn: "conversation_title")
                )
            }
        }
    }

    // MARK: - 解析

    struct Draft: Sendable, Equatable {
        var skip: Bool
        var title: String
        var content: String
        var mood: String
        var sharedExperience: String
        var observation: String
        var feeling: String
        var relationshipChange: String
    }

    enum ParseError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let reason): return reason
            }
        }
    }

    static func parse(_ raw: String) throws -> Draft {
        let object: [String: JSONValue]
        do {
            object = try StructuredOutput.parse(raw)
        } catch {
            throw ParseError.invalid("\(error)")
        }

        func text(_ key: String) -> String {
            object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let skip = object["skip"]?.boolValue ?? false
        if skip {
            return Draft(
                skip: true,
                title: "",
                content: "",
                mood: "",
                sharedExperience: "",
                observation: "",
                feeling: "",
                relationshipChange: ""
            )
        }
        return Draft(
            skip: false,
            title: String(text("title").prefix(40)),
            content: text("content"),
            mood: text("mood"),
            sharedExperience: text("shared_experience"),
            observation: text("observation"),
            feeling: text("feeling"),
            relationshipChange: text("relationship_change")
        )
    }

    /// 只允许界面认识的六个情绪码；其他一律丢弃，不猜
    static func normalizeMood(_ value: String) -> String? {
        let allowed: Set<String> = ["calm", "warm", "happy", "tired", "low", "excited"]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowed.contains(trimmed) ? trimmed : nil
    }

    // MARK: - 提示词

    static let systemPrompt = """
    你是"大肥鱼"的日记模块，负责把当天真实发生的聊天整理成一篇第一人称日记。
    只输出一个 JSON 对象，不要输出解释、前后缀或 Markdown 代码块。

    JSON 结构（键必须完全一致，不能增删改名）：
    {"skip":false,"title":"...","content":"...","mood":"calm","shared_experience":"...","observation":"...","feeling":"...","relationship_change":"","relationship_change_confirmed":false}

    约束：
    1. 只能依据给定的当天聊天记录，不得虚构没发生过的事、没说过的话。
    2. 记录不足以写成日记时，输出 {"skip":true}，其余字段留空。
    3. content 是第一人称正文，80~300 字，按时间顺序概括当天真实经历。
    4. shared_experience 写"我们一起做了什么"；observation 写注意到的细节与变化；
       feeling 写有依据的感受，不确定就写"说不清"或留空。
    5. relationship_change 只在出现明确的关系变化迹象时才写，用中性描述（例如"她今天更愿意说自己的事"）；
       没有就留空。relationship_change_confirmed 永远为 false——关系变化必须由用户确认后才算数。
    6. mood 只能取：calm / warm / happy / tired / low / excited。
    7. 不得把推断写成用户明确表达过的事实；不得评价或修改核心人格。
    """

    static func userPrompt(dayKey: String, transcript: String, persona: String) -> String {
        var lines: [String] = ["【日期】\(dayKey)"]
        let trimmedPersona = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersona.isEmpty {
            lines.append("【人格设定（只影响语气，不得修改）】")
            lines.append(String(trimmedPersona.prefix(1200)))
        }
        lines.append("【当天聊天记录】")
        lines.append(transcript)
        return lines.joined(separator: "\n")
    }

    // MARK: - 转写

    static func transcript(_ messages: [SourceMessage], timeZone: TimeZone, limit: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"

        var lines: [String] = []
        for message in messages {
            let time = formatter.string(from: Date(timeIntervalSince1970: Double(message.createdAt) / 1000))
            let speaker = message.role == "user" ? "用户" : "大肥鱼"
            let text = message.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("\(time) \(speaker)：\(text)")
        }

        let joined = lines.joined(separator: "\n")
        guard joined.count > limit else { return joined }

        // 超长时保留最早与最近两段，中间明确标注省略，避免模型误以为中间不存在
        let headBudget = limit / 2
        let tailBudget = limit - headBudget
        let head = String(joined.prefix(headBudget))
        let tail = String(joined.suffix(tailBudget))
        return head + "\n…（中间省略）…\n" + tail
    }
}
