import SwiftUI
import DFCore

/// 记忆详情：看全文、看来源、看版本，并且能真正修正 / 归档 / 删除 / 恢复。
///
/// 删除是软删：原始聊天与日记不动，但同一内容不会被自动重新提取（见 MemoryProcessingService 的抑制逻辑）。
@MainActor
struct MemoryDetailView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let record: MemoryRecord
    /// 完成操作后回传一句提示，由列表刷新
    let onChanged: (String) -> Void

    @State private var current: MemoryRecord
    @State private var sources: [MemorySourceRef] = []
    @State private var versions: [MemoryVersionRecord] = []
    @State private var isBusy = false
    @State private var message: String?
    @State private var editing = false
    @State private var confirmDelete = false

    init(record: MemoryRecord, onChanged: @escaping (String) -> Void) {
        self.record = record
        self.onChanged = onChanged
        _current = State(initialValue: record)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let message {
                    Text(message)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.primaryDeep)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(DFColor.primarySoft)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                metaCard
                if !sources.isEmpty { sourcesCard }
                if !versions.isEmpty { versionsCard }
                actionRow
            }
            .padding(14)
        }
        .background(DFColor.canvas)
        .navigationTitle("记忆详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                MemoryEditView(title: current.title, content: current.content) { title, content in
                    await save(title: title, content: content)
                }
                .environmentObject(container)
            }
        }
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除记忆", role: .destructive) {
                Task { await softDelete() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原始聊天和日记不会被删除；同一内容也不会被自动重新提取。")
        }
    }

    // MARK: - 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(current.title.isEmpty ? "未命名记忆" : current.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            HStack(spacing: 6) {
                tag(scopeTitle(current.scope))
                tag(layerTitle(current.layer))
                if !current.category.isEmpty { tag(categoryTitle(current.category)) }
                if current.isArchived { tag("已归档") }
            }

            Text(current.content)
                .font(.system(size: 14))
                .foregroundStyle(DFColor.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("重要度", String(format: "%.2f（%@）", current.importanceScore ?? current.salience, current.importanceSource))
            row("可信度", String(format: "%.2f", current.confidence))
            row("信息来源", sourceKindTitle(current.sourceKind))
            row("认识状态", epistemicTitle(current.epistemicStatus))
            row("状态", current.status)
            row("首次记录", MemoryView.dateTimeText(current.firstSeenAt))
            row("最近更新", MemoryView.dateTimeText(current.updatedAt))
            if let recalled = current.lastRecalledAt {
                row("最近想起", "\(MemoryView.dateTimeText(recalled))（共 \(current.recallCount) 次）")
            }
            row("版本", "v\(current.version)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("来源（可以追溯回原始内容）")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sourceTypeTitle(source.sourceType)) · \(source.sourceID)")
                        .font(.system(size: 10))
                        .foregroundStyle(DFColor.inkMuted)
                        .lineLimit(1)
                    if !source.excerpt.isEmpty {
                        Text(source.excerpt)
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.ink)
                            .lineLimit(3)
                    }
                    if let at = source.at {
                        Text(MemoryView.dateTimeText(at))
                            .font(.system(size: 9))
                            .foregroundStyle(DFColor.inkMuted.opacity(0.8))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DFColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var versionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("历史版本（每次修正都会留档）")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            ForEach(versions.reversed()) { version in
                VStack(alignment: .leading, spacing: 2) {
                    Text("v\(version.version) · \(MemoryView.dateTimeText(version.createdAt)) · \(version.changedBy)")
                        .font(.system(size: 10))
                        .foregroundStyle(DFColor.inkMuted)
                    Text(version.title.isEmpty ? version.content : version.title)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.ink)
                        .lineLimit(2)
                    if !version.changeReason.isEmpty {
                        Text(version.changeReason)
                            .font(.system(size: 9))
                            .foregroundStyle(DFColor.inkMuted.opacity(0.8))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DFColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var actionRow: some View {
        VStack(spacing: 8) {
            Button {
                editing = true
            } label: {
                actionLabel("修正内容", icon: "square.and.pencil", color: DFColor.primaryDeep)
            }
            .buttonStyle(.plain)
            .disabled(isBusy || current.isDeleted)

            if current.isDeleted {
                Button {
                    Task { await restore() }
                } label: {
                    actionLabel("恢复这条记忆", icon: "arrow.uturn.backward", color: DFColor.success)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            } else {
                Button {
                    Task { await toggleArchive() }
                } label: {
                    actionLabel(
                        current.isArchived ? "取消归档" : "归档（保留但不再主动调用）",
                        icon: "archivebox",
                        color: DFColor.inkMuted
                    )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button {
                    confirmDelete = true
                } label: {
                    actionLabel("删除这条记忆", icon: "trash", color: DFColor.danger)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }

    // MARK: - 数据

    private func refresh() async {
        if let latest = try? await container.memories.memory(id: current.id) {
            current = latest
        }
        sources = (try? await container.memories.sources(memoryID: current.id)) ?? []
        versions = (try? await container.memories.versions(memoryID: current.id)) ?? []
    }

    private func save(title: String, content: String) async {
        do {
            let updated = try await container.memories.updateContent(
                id: current.id,
                title: title,
                content: content,
                changedBy: "user",
                reason: "用户手动修正",
                at: Clock.nowMillis()
            )
            current = updated
            message = "已保存，并保留修正前的版本"
            onChanged("记忆已修正")
            await refresh()
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    private func toggleArchive() async {
        isBusy = true
        do {
            if current.isArchived {
                try await container.memories.restore(id: current.id)
                message = "已取消归档"
            } else {
                try await container.memories.archive(id: current.id, at: Clock.nowMillis())
                message = "已归档：保留内容，但不会再被主动检索"
            }
            onChanged(message ?? "已更新")
            await refresh()
        } catch {
            message = "操作失败：\(error.localizedDescription)"
        }
        isBusy = false
    }

    private func softDelete() async {
        isBusy = true
        do {
            try await container.memories.softDelete(id: current.id, at: Clock.nowMillis())
            message = "已删除。原始聊天与日记保留，同一内容不会被自动重新提取。"
            onChanged("记忆已删除")
            await refresh()
        } catch {
            message = "删除失败：\(error.localizedDescription)"
        }
        isBusy = false
    }

    private func restore() async {
        isBusy = true
        do {
            try await container.memories.restore(id: current.id)
            message = "已恢复"
            onChanged("记忆已恢复")
            await refresh()
        } catch {
            message = "恢复失败：\(error.localizedDescription)"
        }
        isBusy = false
    }

    // MARK: - 小组件

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(DFColor.inkMuted)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(DFColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(DFColor.primaryDeep)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DFColor.primarySoft, in: Capsule())
    }

    // MARK: - 文案

    private func scopeTitle(_ scope: MemoryScope) -> String {
        switch scope {
        case .user: return "用户"
        case .shared: return "共同"
        case .selfScope: return "自我"
        }
    }

    private func layerTitle(_ layer: String) -> String {
        switch layer {
        case "episodic": return "情景"
        case "semantic": return "语义"
        case "procedural": return "习惯"
        case "reflective": return "反思"
        default: return layer.isEmpty ? "记忆" : layer
        }
    }

    private func categoryTitle(_ category: String) -> String {
        switch category {
        case "preference": return "偏好"
        case "fact": return "事实"
        case "event": return "事件"
        case "relationship": return "关系"
        case "reflection": return "反思"
        case "plan": return "计划"
        default: return category
        }
    }

    private func sourceKindTitle(_ kind: String) -> String {
        switch kind {
        case "real_interaction": return "真实聊天"
        case "diary": return "日记"
        case "model_reflection": return "模型反思"
        case "migration": return "AstrBot 迁移"
        case "import": return "导入"
        default: return kind.isEmpty ? "未标注" : kind
        }
    }

    private func sourceTypeTitle(_ type: String) -> String {
        switch type {
        case "message": return "消息"
        case "diary": return "日记"
        case "attachment": return "附件"
        case "reflection_material": return "反思素材"
        default: return type
        }
    }

    private func epistemicTitle(_ status: String) -> String {
        switch status {
        case "observed": return "明确表达 / 亲眼所见"
        case "inferred": return "推断"
        case "proposed": return "建议"
        case "unconfirmed": return "待确认"
        case "corrected": return "已被用户纠正"
        default: return status.isEmpty ? "未标注" : status
        }
    }
}

/// 修正记忆：只允许改标题与正文，其他元数据（来源、重要度、版本）由系统维护。
@MainActor
private struct MemoryEditView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let content: String
    let onSave: (String, String) async -> Void

    @State private var draftTitle: String
    @State private var draftContent: String
    @State private var isSaving = false

    init(title: String, content: String, onSave: @escaping (String, String) async -> Void) {
        self.title = title
        self.content = content
        self.onSave = onSave
        _draftTitle = State(initialValue: title)
        _draftContent = State(initialValue: content)
    }

    var body: some View {
        Form {
            Section("标题") {
                TextField("一句话概括", text: $draftTitle)
            }
            Section("正文") {
                TextEditor(text: $draftContent)
                    .frame(minHeight: 160)
            }
            Section {
                Text("保存后会追加一个历史版本，旧内容不会被覆盖；修正立即影响之后的检索。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("修正记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    Task {
                        isSaving = true
                        await onSave(
                            draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                            draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        isSaving = false
                        dismiss()
                    }
                }
                .disabled(isSaving || draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
