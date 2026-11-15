import SwiftUI
import DFCore
import DFData

/// 日记编辑：正文 + 结构化记录（共同经历 / 观察 / 感受 / 关系变化）。
/// 保存会追加一版全量快照；关系变化必须由用户勾选确认后才算生效。
@MainActor
struct DiaryEditorView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    private let existing: DiaryEntry?
    private let onSaved: () async -> Void

    @State private var entryDate: String
    @State private var title: String
    @State private var content: String
    @State private var moodCode: String?
    @State private var sharedExperience: String
    @State private var observation: String
    @State private var feeling: String
    @State private var relationshipChange: String
    @State private var relationshipChangeConfirmed: Bool

    @State private var savedEntryID: String?
    @State private var savedMemoryID: String?
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    init(date: String, existing: DiaryEntry?, onSaved: @escaping () async -> Void) {
        self.existing = existing
        self.onSaved = onSaved
        _entryDate = State(initialValue: existing?.entryDate ?? date)
        _title = State(initialValue: existing?.title ?? "")
        _content = State(initialValue: existing?.content ?? "")
        _moodCode = State(initialValue: existing?.moodCode)
        _sharedExperience = State(initialValue: existing?.sharedExperience ?? "")
        _observation = State(initialValue: existing?.observation ?? "")
        _feeling = State(initialValue: existing?.feeling ?? "")
        _relationshipChange = State(initialValue: existing?.relationshipChange ?? "")
        _relationshipChangeConfirmed = State(initialValue: existing?.relationshipChangeConfirmed ?? false)
        _savedEntryID = State(initialValue: existing?.id)
        _savedMemoryID = State(initialValue: existing?.memoryID)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                dateCard
                moodCard
                contentCard
                structuredCard
                actions
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(DFColor.canvas)
        .navigationTitle(savedEntryID == nil ? "写日记" : "编辑日记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") {
                    Task { await save() }
                }
                .disabled(isWorking || trimmedContent.isEmpty)
            }
        }
        .confirmationDialog("删除这篇日记？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await deleteEntry() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("历史版本会保留；删除后可以重新写这一天的日记。")
        }
    }

    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRelationshipChange: String {
        relationshipChange.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否填写了任一结构化字段（决定能否提炼人格提案）
    private var hasStructuredNotes: Bool {
        ![sharedExperience, observation, feeling, relationshipChange]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - 日期与情绪

    private var dateCard: some View {
        HStack(spacing: 10) {
            Text("日期")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            TextField("yyyy-MM-dd", text: $entryDate)
                .font(DFFont.caption)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(DFColor.ink)
        }
        .padding(14)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    private var moodCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今天的心情")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    moodChip(title: "不记录", code: nil)
                    ForEach(DiaryMood.allCases) { mood in
                        moodChip(title: mood.title, code: mood.rawValue)
                    }
                }
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

    private func moodChip(title: String, code: String?) -> some View {
        let selected = moodCode == code
        return Button {
            moodCode = code
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? DFColor.surface : DFColor.inkMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? DFColor.primary : DFColor.surfaceAlt, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 正文

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正文")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DFColor.ink)

            TextField("标题（可留空）", text: $title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DFColor.ink)
                .padding(10)
                .background(DFColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("用第一人称写，像在跟未来的自己说话")
                .font(.system(size: 10))
                .foregroundStyle(DFColor.inkMuted)

            TextEditor(text: $content)
                .font(DFFont.caption)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 132)
                .padding(6)
                .background(DFColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text("\(trimmedContent.count) 字")
                .font(.system(size: 10))
                .foregroundStyle(DFColor.inkMuted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .background(DFColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous)
                .stroke(DFColor.hairline, lineWidth: 1)
        )
    }

    // MARK: - 结构化记录

    private var structuredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("结构化记录")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Text("可只写其中几项；留空表示这一天没有需要单独记录的内容。观察与关系变化可在保存后提炼成待确认的人格提案。")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }

            noteField(
                title: "共同经历",
                hint: "我们一起做了什么",
                text: $sharedExperience
            )
            noteField(
                title: "观察",
                hint: "看到的细节、她的变化",
                text: $observation
            )
            noteField(
                title: "感受",
                hint: "当时的情绪与身体感受",
                text: $feeling
            )
            noteField(
                title: "关系变化",
                hint: "例如：今天开始愿意说心事了",
                text: $relationshipChange
            )

            if !trimmedRelationshipChange.isEmpty {
                Toggle(isOn: $relationshipChangeConfirmed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("我已确认这段关系变化")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DFColor.ink)
                        Text("未确认时只作为观察保留，不会影响关系阶段。")
                            .font(.system(size: 10))
                            .foregroundStyle(DFColor.inkMuted)
                    }
                }
                .tint(DFColor.primary)
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

    private func noteField(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DFColor.primaryDeep)
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(DFColor.inkMuted)
                    .lineLimit(1)
            }

            TextEditor(text: text)
                .font(DFFont.caption)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56)
                .padding(6)
                .background(DFColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 操作

    private var actions: some View {
        VStack(spacing: 8) {
            if let message {
                Text(message)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await save() }
            } label: {
                Text(isWorking ? "处理中…" : "保存日记")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DFColor.surface)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DFColor.primary, in: RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isWorking || trimmedContent.isEmpty)

            if savedEntryID != nil {
                Button {
                    Task { await distill() }
                } label: {
                    Text(savedMemoryID == nil ? "沉淀为长期记忆" : "已沉淀为长期记忆")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(savedMemoryID == nil ? DFColor.primaryDeep : DFColor.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(DFColor.primarySoft, in: RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isWorking || savedMemoryID != nil)
            }

            if savedEntryID != nil && hasStructuredNotes {
                Button {
                    Task { await proposePersona() }
                } label: {
                    Text("从日记提炼人格提案")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DFColor.primaryDeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(DFColor.lilacSoft, in: RoundedRectangle(cornerRadius: DFRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }

            if savedEntryID != nil {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("删除这篇日记")
                        .font(.system(size: 12))
                        .foregroundStyle(DFColor.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 行为

    private func save() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }

        let request = DiaryUpsert(
            entryDate: entryDate,
            title: title,
            content: content,
            moodCode: moodCode,
            source: existing?.source ?? "manual",
            generatedBy: existing?.generatedBy,
            isUserEdited: true,
            memoryID: savedMemoryID,
            sharedExperience: sharedExperience,
            observation: observation,
            feeling: feeling,
            relationshipChange: relationshipChange,
            relationshipChangeConfirmed: relationshipChangeConfirmed && !trimmedRelationshipChange.isEmpty,
            changeReason: savedEntryID == nil ? "用户创建" : "用户编辑",
            changedBy: "user"
        )

        do {
            let saved = try await container.diary.upsert(request, at: Clock.nowMillis())
            savedEntryID = saved.id
            savedMemoryID = saved.memoryID
            message = "已保存，历史版本已留档"
            await onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func distill() async {
        guard let id = savedEntryID, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }

        let service = DiaryMemoryService(diary: container.diary, processing: container.memoryProcessing)
        do {
            let outcome = try await service.distill(entryID: id, at: Clock.nowMillis())
            switch outcome {
            case .distilled(let memoryIDs, let proposalIDs):
                if let memoryID = memoryIDs.first {
                    savedMemoryID = memoryID
                    message = "已沉淀为长期记忆"
                } else if !proposalIDs.isEmpty {
                    message = "已生成待确认的记忆提案，请到审批中心确认"
                } else {
                    message = "已提交沉淀，暂未写入新记忆"
                }
            case .alreadyDistilled(let memoryID):
                savedMemoryID = memoryID
                message = "这篇日记已经沉淀过了"
            case .nothingToDistill:
                message = "正文为空，暂无可沉淀内容"
            }
            await onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// D18：把「观察 / 关系变化」提炼成待审批的人格提案
    private func proposePersona() async {
        guard let id = savedEntryID, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }

        do {
            guard let entry = try await container.diary.entry(id: id) else {
                errorMessage = "日记不存在，请先保存再提炼"
                return
            }
            let service = DiaryPersonaProposalService(
                database: container.database,
                growth: container.personaGrowth
            )
            let outcome = try await service.propose(from: entry)
            if outcome.proposalIDs.isEmpty {
                message = "没有新的可提炼内容（已有相同条目或待审批提案）"
            } else {
                message = "已生成 \(outcome.proposalIDs.count) 条待审批的人格提案，请到审批中心确认"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEntry() async {
        guard let id = savedEntryID, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await container.diary.softDelete(id: id, at: Clock.nowMillis())
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
