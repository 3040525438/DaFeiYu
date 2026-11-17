import Foundation
import GRDB
import DFCore

/// 自我反思（L5）的可查看记录 + 手动触发（D32）。
///
/// 边界：
/// - 反思只能基于**已存在的记忆/情景**引用，不允许凭空编造经历；
/// - 模型返回的结论会先过 `ReflectionPolicy`，不合法或被拒的结论直接丢弃；
/// - 反思结论不修改核心人格，只作为"自身记忆"沉淀或提案。
public struct ReflectionRecord: Sendable, Identifiable {
    public var id: String
    public var scope: String
    public var kind: String
    public var subject: String
    public var content: String
    public var conclusion: String
    public var confidence: Double
    public var epistemicStatus: String
    public var createdAt: Int64
}

public struct ReflectionAutoService: Sendable {
    private let database: AppDatabase
    private let memories: MemoryRepository
    private let processing: MemoryProcessingService
    private let now: @Sendable () -> Int64

    public init(
        database: AppDatabase,
        memories: MemoryRepository,
        processing: MemoryProcessingService,
        now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }
    ) {
        self.database = database
        self.memories = memories
        self.processing = processing
        self.now = now
    }

    /// 最近的反思记录（只读展示）。
    public func recent(limit: Int = 20) async throws -> [ReflectionRecord] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, scope, kind, subject, content, conclusion,
                       confidence, epistemic_status, created_at
                FROM reflections
                WHERE status = 'active'
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [min(max(limit, 1), 100)]
            )
            return rows.map { row in
                ReflectionRecord(
                    id: (try? row.decode(String.self, forColumn: "id")) ?? "",
                    scope: (try? row.decode(String.self, forColumn: "scope")) ?? "",
                    kind: (try? row.decode(String.self, forColumn: "kind")) ?? "",
                    subject: (try? row.decode(String.self, forColumn: "subject")) ?? "",
                    content: (try? row.decode(String.self, forColumn: "content")) ?? "",
                    conclusion: (try? row.decode(String.self, forColumn: "conclusion")) ?? "",
                    confidence: (try? row.decode(Double.self, forColumn: "confidence")) ?? 0,
                    epistemicStatus: (try? row.decode(String.self, forColumn: "epistemic_status")) ?? "",
                    createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0
                )
            }
        }
    }

    /// 用真实记忆做一次反思。
    ///
    /// - Returns: 写入的反思条数；素材不足时返回 0，不编造。
    @discardableResult
    public func run(
        provider: ChatModelProvider,
        model: String,
        personaNote: String = ""
    ) async throws -> Int {
        // 1. 取材：只拿真实存在、未删除的记忆
        let materials = try await memories.memories(
            scope: .selfScope,
            layer: nil,
            includeArchived: false,
            limit: 20,
            offset: 0
        ) + (try await memories.memories(
            scope: .user,
            layer: nil,
            includeArchived: false,
            limit: 20,
            offset: 0
        ))
        guard materials.count >= 3 else { return 0 }

        let ids = materials.map(\.id)
        let materialText = materials.prefix(30).map { record in
            let body = record.content.isEmpty ? record.title : record.content
            return "- [\(record.id)] \(body.prefix(120))"
        }.joined(separator: "\n")

        let systemPrompt = """
        你在做一次自我反思。只能引用下面给出的记忆，不能编造任何经历或事实。
        输出严格 JSON：
        {"conclusions":[{"content":"观察到的现象","conclusion":"你从中得到的判断","evidence_refs":["记忆ID"]}]}
        规则：
        1. 最多 3 条结论，每条必须至少引用 1 个真实记忆 ID；
        2. 不确定的内容不要写；没有值得反思的就返回 {"conclusions":[]}；
        3. 不要修改人格设定，不要给出用户没表达过的偏好。
        \(personaNote.isEmpty ? "" : "\n当前人格基调：\(personaNote)")
        """

        let request = ChatRequest(
            model: model,
            systemPrompt: systemPrompt,
            messages: [
                ChatTurn(role: .user, text: "可引用的记忆：\n\(materialText)")
            ],
            temperature: 0.3,
            maxTokens: 700
        )

        let raw = try await StructuredChatRunner.collect(provider: provider, request: request)

        // `StructuredOutput.parse` 是 throwing 且返回非可选字典
        let object: [String: JSONValue]
        do {
            object = try StructuredOutput.parse(raw)
        } catch {
            throw DFError.decoding("反思输出不是合法 JSON：\(error)")
        }
        guard let items = object["conclusions"]?.arrayValue else { return 0 }

        var conclusions: [ReflectionConclusion] = []
        for item in items {
            guard let dict = item.objectValue,
                  let content = dict["content"]?.stringValue,
                  let conclusion = dict["conclusion"]?.stringValue else { continue }
            let refs = (dict["evidence_refs"]?.arrayValue ?? []).compactMap { $0.stringValue }
            guard !refs.isEmpty else { continue }
            conclusions.append(
                ReflectionConclusion(
                    content: content,
                    conclusion: conclusion,
                    evidenceRefs: refs
                )
            )
        }
        guard !conclusions.isEmpty else { return 0 }

        let draft = ReflectionDraft(
            scope: .selfScope,
            kind: "manual",
            subject: "手动反思",
            conclusions: conclusions,
            availableRefs: ids,
            confidence: 0.6,
            depositStableSelfMemories: false
        )
        let outcome = try await processing.reflect(draft)
        return outcome.reflectionIDs.count
    }
}
