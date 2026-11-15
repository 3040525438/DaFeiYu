import Foundation
import DFCore

/// 单条导入候选：解析结果与现有外围人格条目的比对结论。
public struct PersonaImportCandidate: Sendable, Equatable, Identifiable {
    public enum Action: String, Sendable {
        /// 外围人格里还没有这个条目
        case create
        /// 已有同 section + key 但内容不同
        case update
        /// 已有且内容一致，无需提案
        case unchanged
    }

    public var section: String
    public var key: String
    public var value: String
    /// 已有条目 id（update 时用于定位）
    public var existingItemID: String?
    public var existingValue: String?
    public var action: Action

    public var id: String { "\(section)|\(key)" }

    public init(
        section: String,
        key: String,
        value: String,
        existingItemID: String? = nil,
        existingValue: String? = nil,
        action: Action
    ) {
        self.section = section
        self.key = key
        self.value = value
        self.existingItemID = existingItemID
        self.existingValue = existingValue
        self.action = action
    }
}

/// 导入预览：只读比对，不写库。
public struct PersonaImportPlan: Sendable, Equatable {
    public var fileName: String
    public var documentName: String?
    public var candidates: [PersonaImportCandidate]
    public var warnings: [String]

    public var createdCount: Int { candidates.filter { $0.action == .create }.count }
    public var updatedCount: Int { candidates.filter { $0.action == .update }.count }
    public var unchangedCount: Int { candidates.filter { $0.action == .unchanged }.count }
    /// 需要用户审批的提案数
    public var proposalCount: Int { createdCount + updatedCount }

    public init(
        fileName: String,
        documentName: String?,
        candidates: [PersonaImportCandidate],
        warnings: [String]
    ) {
        self.fileName = fileName
        self.documentName = documentName
        self.candidates = candidates
        self.warnings = warnings
    }
}

/// 导入结果：只生成待审批提案，不直接改人格。
public struct PersonaImportResult: Sendable, Equatable {
    public var plan: PersonaImportPlan
    public var personaID: String
    /// 新生成的待审批提案 id
    public var proposalIDs: [String]
    /// 已存在同内容的 pending 提案而被跳过的条数
    public var alreadyPendingCount: Int

    public init(
        plan: PersonaImportPlan,
        personaID: String,
        proposalIDs: [String],
        alreadyPendingCount: Int
    ) {
        self.plan = plan
        self.personaID = personaID
        self.proposalIDs = proposalIDs
        self.alreadyPendingCount = alreadyPendingCount
    }
}

/// 人格文件导入（D06）。
///
/// 硬规则：
/// - 文件内容只进入**待审批提案**，不直接写 `persona_items`；
/// - 只作用于外围人格，核心人格永远不受影响；
/// - 与现有条目完全一致的行不会产生噪音提案；
/// - 同 section + key + 内容 已有 pending 提案时跳过，避免重复堆积。
public final class PersonaFileImportService: @unchecked Sendable {
    public static let defaultPersonaName = "外围人格"

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

    // MARK: - 预览

    public func preview(data: Data, fileName: String) async throws -> PersonaImportPlan {
        let document = try PersonaFileParser.parse(data: data, fileName: fileName)
        let existing = try await personas.outerItems()
        return Self.makePlan(document: document, existing: existing, fileName: fileName)
    }

    // MARK: - 导入（生成提案）

    public func apply(
        data: Data,
        fileName: String,
        personaName: String = PersonaFileImportService.defaultPersonaName
    ) async throws -> PersonaImportResult {
        let document = try PersonaFileParser.parse(data: data, fileName: fileName)
        let persona = try await personas.ensureOuterPersona(name: personaName)
        let existing = try await personas.outerItems()
        let plan = Self.makePlan(document: document, existing: existing, fileName: fileName)

        let pending = try await growth.proposals(personaID: persona.id)
            .filter { $0.status == "pending" }

        var proposalIDs: [String] = []
        var alreadyPending = 0
        for candidate in plan.candidates where candidate.action != .unchanged {
            let duplicated = pending.contains {
                $0.section == candidate.section
                    && $0.key == candidate.key
                    && $0.toValue == candidate.value
            }
            if duplicated {
                alreadyPending += 1
                continue
            }
            let draft = PersonaGrowthDraft(
                personaID: persona.id,
                itemID: candidate.existingItemID,
                section: candidate.section,
                key: candidate.key,
                fromValue: candidate.existingValue ?? "",
                toValue: candidate.value,
                reason: candidate.action == .create
                    ? "从人格文件「\(fileName)」新增"
                    : "从人格文件「\(fileName)」更新",
                evidenceJSON: Self.evidenceJSON(fileName: fileName, candidate: candidate)
            )
            let proposal = try await growth.propose(draft)
            proposalIDs.append(proposal.id)
        }

        return PersonaImportResult(
            plan: plan,
            personaID: persona.id,
            proposalIDs: proposalIDs,
            alreadyPendingCount: alreadyPending
        )
    }

    // MARK: - 内部

    private static func makePlan(
        document: ParsedPersonaDocument,
        existing: [PersonaItem],
        fileName: String
    ) -> PersonaImportPlan {
        var byIdentity: [String: PersonaItem] = [:]
        for item in existing {
            let identity = "\(item.section)|\(item.key)"
            if byIdentity[identity] == nil {
                byIdentity[identity] = item
            }
        }

        let candidates = document.items.map { item -> PersonaImportCandidate in
            let identity = "\(item.section)|\(item.key)"
            guard let current = byIdentity[identity] else {
                return PersonaImportCandidate(
                    section: item.section,
                    key: item.key,
                    value: item.value,
                    action: .create
                )
            }
            let same = current.value.trimmingCharacters(in: .whitespacesAndNewlines)
                == item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return PersonaImportCandidate(
                section: item.section,
                key: item.key,
                value: item.value,
                existingItemID: current.id,
                existingValue: current.value,
                action: same ? .unchanged : .update
            )
        }

        return PersonaImportPlan(
            fileName: fileName,
            documentName: document.name,
            candidates: candidates,
            warnings: document.warnings
        )
    }

    /// 证据里保留文件名与原始行，审批中心可追溯来源
    private static func evidenceJSON(fileName: String, candidate: PersonaImportCandidate) -> String {
        let evidence = PersonaFileEvidence(
            fileName: fileName,
            section: candidate.section,
            key: candidate.key,
            value: candidate.value
        )
        guard let data = try? JSONEncoder().encode([evidence]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

private struct PersonaFileEvidence: Codable {
    var source = "persona_file"
    var fileName: String
    var section: String
    var key: String
    var value: String
}
