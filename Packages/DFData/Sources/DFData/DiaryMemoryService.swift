import Foundation
import DFCore

/// 日记 → 长期记忆的自动沉淀（W8-2 / D35）。
///
/// 规则：
/// - 已沉淀（`memoryID` 非空）的日记不重复抽取；
/// - 只取正文第一段作为一条情景候选，证据必须逐字来自正文；
/// - 归属与是否需确认交给 `MemoryGovernance` / `MemoryProcessingService`，这里不越权直接写库；
/// - 沉淀成功后只回填 `memory_id`，不改正文、不追加版本快照。
public struct DiaryMemoryService: Sendable {
    public enum Outcome: Sendable, Equatable {
        case distilled(memoryIDs: [String], proposalIDs: [String])
        case alreadyDistilled(String)
        case nothingToDistill
    }

    private let diary: DiaryRepository
    private let processing: MemoryProcessingService
    private let maxCharacters: Int

    public init(
        diary: DiaryRepository,
        processing: MemoryProcessingService,
        maxCharacters: Int = 400
    ) {
        self.diary = diary
        self.processing = processing
        self.maxCharacters = max(50, maxCharacters)
    }

    /// 把一篇日记沉淀成记忆。返回实际写入/提案的记忆 ID，供界面展示。
    @discardableResult
    public func distill(entryID: String, at millis: Int64) async throws -> Outcome {
        guard let entry = try await diary.entry(id: entryID), !entry.isDeleted else {
            throw DiaryError.notFound
        }
        if let memoryID = entry.memoryID, !memoryID.isEmpty {
            return .alreadyDistilled(memoryID)
        }

        let content = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return .nothingToDistill }

        let paragraph = Self.firstParagraph(of: content, limit: maxCharacters)
        guard !paragraph.isEmpty else { return .nothingToDistill }

        let candidate = MemoryCandidate(
            scope: .shared,
            layer: .episodic,
            category: "event",
            title: Self.title(for: entry),
            content: paragraph,
            evidenceQuote: paragraph,
            importance: 0.6,
            confidence: 0.8,
            epistemicStatus: "observed",
            sourceKind: "diary",
            scopeNeedsConfirmation: false
        )

        let turn = MemoryTurnSource(
            conversationID: "diary:\(entry.id)",
            userMessageID: "diary:\(entry.id):\(entry.entryDate)",
            text: content,
            at: millis
        )

        let report = try await processing.ingest([candidate], from: turn)
        if let memoryID = report.writtenMemoryIDs.first {
            try await diary.attachMemory(id: entry.id, memoryID: memoryID, at: millis)
        }
        return .distilled(memoryIDs: report.writtenMemoryIDs, proposalIDs: report.proposalIDs)
    }

    /// 取第一段（按换行切分）并截断；证据必须是原文子串，截断后仍可定位。
    static func firstParagraph(of text: String, limit: Int) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(max(1, limit)))
    }

    static func title(for entry: DiaryEntry) -> String {
        let base = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((base.isEmpty ? entry.entryDate : base).prefix(20))
    }
}
