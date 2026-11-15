import Foundation
import DFCore

/// 日记触发人格成长提案的结果（D18）。
public struct DiaryPersonaProposalOutcome: Sendable, Equatable {
    /// 新生成的待审批提案 id
    public var proposalIDs: [String]
    /// 与现有人格条目一致而跳过的条数
    public var skippedExistingCount: Int
    /// 与已有待审批提案一致而跳过的条数
    public var skippedPendingCount: Int

    public init(
        proposalIDs: [String],
        skippedExistingCount: Int,
        skippedPendingCount: Int
    ) {
        self.proposalIDs = proposalIDs
        self.skippedExistingCount = skippedExistingCount
        self.skippedPendingCount = skippedPendingCount
    }
}

/// 从日记的结构化字段提炼外围人格提案（D18）。
///
/// 规则与边界：
/// - 只取「观察」与「关系变化」两类，正文与感受不直接变人格；
/// - 只生成**待审批提案**，用户确认后才写入外围人格；
/// - 与现有人格条目或已有 pending 提案一致时跳过，避免重复堆积；
/// - 不使用模型推理，也不猜测日记里没写的内容。
public final class DiaryPersonaProposalService: @unchecked Sendable {
    private struct Field {
        var name: String
        var section: String
        var keyPrefix: String
        var value: String
    }

    private let personas: GRDBPersonaRepository
    private let growth: PersonaGrowthService

    public init(
        database: AppDatabase,
        personas: GRDBPersonaRepository? = nil,
        growth: PersonaGrowthService? = nil
    ) {
        self.personas = personas ?? GRDBPersonaRepository(database: database)
        self.growth = growth ?? PersonaGrowthService(database: database)
    }

    public func propose(
        from entry: DiaryEntry,
        personaName: String = PersonaFileImportService.defaultPersonaName
    ) async throws -> DiaryPersonaProposalOutcome {
        let fields = Self.fields(from: entry)
        guard !fields.isEmpty else {
            return DiaryPersonaProposalOutcome(
                proposalIDs: [],
                skippedExistingCount: 0,
                skippedPendingCount: 0
            )
        }

        let persona = try await personas.ensureOuterPersona(name: personaName)
        let existing = try await personas.outerItems()
        let pending = try await growth.proposals(personaID: persona.id)
            .filter { $0.status == "pending" }

        var existingMap: [String: String] = [:]
        for item in existing {
            existingMap["\(item.section)|\(item.key)"] = item.value
        }

        var proposalIDs: [String] = []
        var skippedExisting = 0
        var skippedPending = 0

        for field in fields {
            let key = "\(field.keyPrefix)·\(entry.entryDate)"
            if let current = existingMap["\(field.section)|\(key)"],
               current.trimmingCharacters(in: .whitespacesAndNewlines)
                == field.value.trimmingCharacters(in: .whitespacesAndNewlines) {
                skippedExisting += 1
                continue
            }
            let duplicated = pending.contains {
                $0.section == field.section && $0.key == key && $0.toValue == field.value
            }
            if duplicated {
                skippedPending += 1
                continue
            }

            let draft = PersonaGrowthDraft(
                personaID: persona.id,
                itemID: nil,
                section: field.section,
                key: key,
                fromValue: "",
                toValue: field.value,
                reason: "从日记《\(Self.displayTitle(entry))》的「\(field.name)」提炼，需你确认后才会写入外围人格",
                evidenceJSON: Self.evidenceJSON(entry: entry, field: field)
            )
            let proposal = try await growth.propose(draft)
            proposalIDs.append(proposal.id)
        }

        return DiaryPersonaProposalOutcome(
            proposalIDs: proposalIDs,
            skippedExistingCount: skippedExisting,
            skippedPendingCount: skippedPending
        )
    }

    // MARK: - 内部

    private static func fields(from entry: DiaryEntry) -> [Field] {
        var result: [Field] = []
        let observation = entry.observation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !observation.isEmpty {
            result.append(Field(name: "观察", section: "日记观察", keyPrefix: "观察", value: observation))
        }
        let change = entry.relationshipChange.trimmingCharacters(in: .whitespacesAndNewlines)
        if !change.isEmpty {
            result.append(
                Field(name: "关系变化", section: "关系变化", keyPrefix: "关系", value: change)
            )
        }
        return result
    }

    private static func displayTitle(_ entry: DiaryEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? entry.entryDate : title
    }

    private static func evidenceJSON(entry: DiaryEntry, field: Field) -> String {
        let evidence = DiaryPersonaEvidence(
            diaryID: entry.id,
            entryDate: entry.entryDate,
            field: field.name,
            quote: field.value
        )
        guard let data = try? JSONEncoder().encode([evidence]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

private struct DiaryPersonaEvidence: Codable {
    var source = "diary"
    var diaryID: String
    var entryDate: String
    var field: String
    var quote: String
}
