import SwiftUI
import DFCore
import DFData

/// 审批中心（D07 / D12 / D18 / D31）：
/// 人格成长、关系阶段、记忆写入三类提案都在这里由用户逐条确认，AI 不能自行生效。
@MainActor
struct ApprovalCenterView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var personaProposals: [PersonaGrowthProposal] = []
    @State private var stageProposals: [RelationshipStageChange] = []
    @State private var memoryProposals: [MemoryProposalItem] = []
    /// AstrBot 导入时因冲突/空内容进入待处理区的条目（此前完全没展示）
    @State private var importPendings: [AstrBotPendingItem] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            memorySection
            importSection
            personaSection
            relationshipSection

            Section {
                if totalPending == 0 {
                    Text("当前没有待确认事项。AI 的新提案会出现在这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("说明")
            } footer: {
                Text("确认会立即写入并留版本；驳回只记录结果，不删除历史。")
            }
        }
        .navigationTitle("待确认事项")
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private var totalPending: Int {
        memoryProposals.count + importPendings.count + personaProposals.count + stageProposals.count
    }

    // MARK: - 导入待确认

    private var importSection: some View {
        Section {
            if importPendings.isEmpty {
                Text("没有待处理的导入条目")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(importPendings) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(importKindText(item.entityKind))
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text(importReasonText(item.reasonCode))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DFColor.primarySoft, in: Capsule())
                                .foregroundStyle(DFColor.primary)
                        }
                        if let sourceID = item.sourceID, !sourceID.isEmpty {
                            Text("来源 ID：\(sourceID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button("标记已处理") {
                                Task { await resolveImportPending(item) }
                            }
                            .font(.caption)
                            .disabled(busy || item.id.isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("AstrBot 导入待确认")
        } footer: {
            Text("导入时因人格冲突、内容为空等原因被拦下的条目都在这里，不会自动写入。")
        }
    }

    private func importKindText(_ kind: String) -> String {
        switch kind {
        case "persona": return "人格"
        case "memory": return "记忆"
        case "diary": return "日记"
        case "document": return "信件/笔记"
        case "message": return "消息"
        default: return kind.isEmpty ? "未知条目" : kind
        }
    }

    private func importReasonText(_ reason: String) -> String {
        switch reason {
        case "persona_conflict": return "人格冲突"
        case "empty_content": return "内容为空"
        default: return reason.isEmpty ? "待确认" : reason
        }
    }

    private func resolveImportPending(_ item: AstrBotPendingItem) async {
        busy = true
        defer { busy = false }
        do {
            try await container.astrbotImporter.resolvePending(
                id: item.id,
                targetID: nil,
                at: Clock.nowMillis()
            )
            await reload()
        } catch {
            message = "标记失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 记忆

    private var memorySection: some View {
        Section {
            if memoryProposals.isEmpty {
                Text("没有待确认的记忆提案")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(memoryProposals) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.title)
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text(riskText(item.risk))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DFColor.primarySoft, in: Capsule())
                                .foregroundStyle(DFColor.primary)
                        }
                        Text(item.content)
                            .font(.system(size: 13))
                        Text("归属：\(scopeText(item.scope)) · 层：\(item.layer) · 类别：\(item.category)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !item.evidenceQuote.isEmpty {
                            Text("原文：\(item.evidenceQuote)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                        actionRow(
                            approve: { await approveMemory(item) },
                            reject: { await rejectMemory(item) }
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("记忆写入（\(memoryProposals.count)）")
        }
    }

    // MARK: - 人格

    private var personaSection: some View {
        Section {
            if personaProposals.isEmpty {
                Text("没有待确认的人格成长提案")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(personaProposals) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(item.section) · \(item.key)")
                            .font(.system(size: 14, weight: .medium))
                        if !item.fromValue.isEmpty {
                            Text("原：\(item.fromValue)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Text("新：\(item.toValue)")
                            .font(.system(size: 13))
                        if !item.reason.isEmpty {
                            Text("理由：\(item.reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        actionRow(
                            approve: { await approvePersona(item) },
                            reject: { await rejectPersona(item) }
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("人格成长（\(personaProposals.count)）")
        }
    }

    // MARK: - 关系

    private var relationshipSection: some View {
        Section {
            if stageProposals.isEmpty {
                Text("没有待确认的关系阶段变更")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(stageProposals) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(stageText(item.fromStage)) → \(stageText(item.toStage))")
                            .font(.system(size: 14, weight: .medium))
                        if !item.reason.isEmpty {
                            Text("理由：\(item.reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        actionRow(
                            approve: { await approveStage(item) },
                            reject: { await rejectStage(item) }
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("关系阶段（\(stageProposals.count)）")
        }
    }

    private func actionRow(
        approve: @escaping () async -> Void,
        reject: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button("确认") { Task { await approve() } }
                .buttonStyle(.borderedProminent)
                .tint(DFColor.primary)
                .font(.caption)
            Button("驳回") { Task { await reject() } }
                .buttonStyle(.bordered)
                .font(.caption)
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .disabled(busy)
    }

    // MARK: - 行为

    private func reload() async {
        do {
            memoryProposals = try await container.memoryProcessing.pendingProposals()
        } catch {
            memoryProposals = []
        }
        do {
            let all = try await container.personaGrowth.proposals()
            personaProposals = all.filter { $0.status == "pending" }
        } catch {
            personaProposals = []
        }
        do {
            let all = try await container.relationships.stageHistory(limit: 100)
            stageProposals = all.filter { $0.status == .pending }
        } catch {
            stageProposals = []
        }
        do {
            importPendings = try await container.astrbotImporter.pendingItems(limit: 100)
        } catch {
            importPendings = []
        }
    }

    private func approveMemory(_ item: MemoryProposalItem) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await container.memoryProcessing.approveProposal(id: item.id)
            message = "已确认写入：\(item.title)"
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func rejectMemory(_ item: MemoryProposalItem) async {
        busy = true
        defer { busy = false }
        do {
            try await container.memoryProcessing.rejectProposal(id: item.id)
            message = "已驳回：\(item.title)"
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func approvePersona(_ item: PersonaGrowthProposal) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await container.personaGrowth.approve(id: item.id)
            message = "人格已更新：\(item.key)"
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func rejectPersona(_ item: PersonaGrowthProposal) async {
        busy = true
        defer { busy = false }
        do {
            try await container.personaGrowth.reject(id: item.id, note: "用户驳回")
            message = "已驳回人格提案：\(item.key)"
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func approveStage(_ item: RelationshipStageChange) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await container.relationships.confirmStageChange(id: item.id, by: "user")
            message = "关系阶段已更新为 \(stageText(item.toStage))"
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func rejectStage(_ item: RelationshipStageChange) async {
        busy = true
        defer { busy = false }
        do {
            try await container.relationships.rejectStageChange(id: item.id, by: "user")
            message = "已驳回关系阶段提案"
            await reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func riskText(_ risk: String) -> String {
        switch risk {
        case "high": return "高影响"
        case "medium": return "中影响"
        default: return "低影响"
        }
    }

    private func scopeText(_ scope: MemoryScope) -> String {
        switch scope {
        case .user: return "关于你"
        case .shared: return "共同经历"
        case .selfScope: return "她自己的成长"
        }
    }

    private func stageText(_ stage: RelationshipStage) -> String {
        switch stage.rawValue {
        case "stranger": return "陌生"
        case "acquaintance": return "认识"
        case "friend": return "朋友"
        case "close_friend": return "亲密朋友"
        case "companion": return "陪伴"
        case "intimate": return "重要关系"
        default: return stage.rawValue
        }
    }
}
