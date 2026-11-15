import SwiftUI
import UniformTypeIdentifiers
import DFCore
import DFData

/// 人格文件导入（D06）：JSON / Markdown / TXT → 预览 → 生成待审批提案。
/// 导入不会直接改人格，所有条目都要在审批中心逐条确认。
@MainActor
struct PersonaImportView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var showPicker = false
    @State private var fileName: String?
    @State private var fileData: Data?
    @State private var plan: PersonaImportPlan?
    @State private var result: PersonaImportResult?
    @State private var busy = false
    @State private var message: String?

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.json, .plainText]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }

    var body: some View {
        List {
            Section {
                Button {
                    showPicker = true
                } label: {
                    Label("选择人格文件…", systemImage: "doc.badge.plus")
                }
                .disabled(busy)

                if let fileName {
                    LabeledContent("已选择", value: fileName)
                        .font(.footnote)
                }
                if busy {
                    ProgressView()
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("导入")
            } footer: {
                Text("支持 JSON（sections 或 items）、Markdown（标题 + 列表）、TXT（[段落] + key: value）。导入只生成待审批提案，不会直接改人格。")
            }

            if let plan {
                previewSection(plan)
            }
            if let result {
                resultSection(result)
            }
        }
        .navigationTitle("导入人格文件")
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: false
        ) { pick in
            Task { await handlePick(pick) }
        }
    }

    // MARK: - 预览

    @ViewBuilder
    private func previewSection(_ plan: PersonaImportPlan) -> some View {
        Section {
            ForEach(plan.candidates) { candidate in
                candidateRow(candidate)
            }
            if plan.candidates.isEmpty {
                Text("文件里没有可导入的条目。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("预览（新增 \(plan.createdCount) · 更新 \(plan.updatedCount) · 不变 \(plan.unchangedCount)）")
        } footer: {
            Text("“不变”的条目不会生成提案；其余条目会进入审批中心，确认后才写入外围人格。")
        }

        Section {
            Button {
                Task { await apply() }
            } label: {
                Label(
                    plan.proposalCount > 0 ? "生成待审批提案（\(plan.proposalCount)）" : "没有需要提交的变更",
                    systemImage: "checkmark.seal"
                )
            }
            .disabled(busy || plan.proposalCount == 0 || result != nil)
        }
    }

    private func candidateRow(_ candidate: PersonaImportCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(candidate.section) · \(candidate.key)")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text(actionTitle(candidate.action))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(actionColor(candidate.action).opacity(0.16), in: Capsule())
                    .foregroundStyle(actionColor(candidate.action))
            }
            if candidate.action == .update, let old = candidate.existingValue {
                Text("原：\(old)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("新：\(candidate.value)")
                    .font(.system(size: 13))
            } else {
                Text(candidate.value)
                    .font(.system(size: 13))
                    .foregroundStyle(candidate.action == .unchanged ? .secondary : .primary)
            }
        }
        .padding(.vertical, 2)
    }

    private func resultSection(_ result: PersonaImportResult) -> some View {
        Section {
            Text("已生成 \(result.proposalIDs.count) 条待审批提案。")
                .font(.system(size: 14, weight: .medium))
            if result.alreadyPendingCount > 0 {
                Text("另有 \(result.alreadyPendingCount) 条与现有待审批提案内容相同，已跳过。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                ApprovalCenterView()
            } label: {
                Label("去审批中心确认", systemImage: "checklist")
            }
        } header: {
            Text("提案已生成")
        } footer: {
            Text("确认后才会写入外围人格并留版本；核心人格始终受写保护。")
        }
    }

    // MARK: - 动作

    private func handlePick(_ pick: Result<[URL], Error>) async {
        switch pick {
        case .success(let urls):
            guard let url = urls.first else { return }
            await load(url)
        case .failure(let error):
            message = "选择文件失败：\(error.localizedDescription)"
        }
    }

    private func load(_ url: URL) async {
        busy = true
        defer { busy = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            fileData = data
            fileName = url.lastPathComponent
            result = nil
            plan = try await container.personaImport.preview(
                data: data,
                fileName: url.lastPathComponent
            )
            message = nil
        } catch {
            plan = nil
            result = nil
            message = "解析失败：\(error.localizedDescription)"
        }
    }

    private func apply() async {
        guard let data = fileData, let name = fileName else { return }
        busy = true
        defer { busy = false }
        do {
            let outcome = try await container.personaImport.apply(data: data, fileName: name)
            result = outcome
            message = outcome.proposalIDs.isEmpty
                ? "没有新增提案（可能需要先处理已有的同内容提案）"
                : "已提交 \(outcome.proposalIDs.count) 条提案"
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 文案

    private func actionTitle(_ action: PersonaImportCandidate.Action) -> String {
        switch action {
        case .create: return "新增"
        case .update: return "更新"
        case .unchanged: return "不变"
        }
    }

    private func actionColor(_ action: PersonaImportCandidate.Action) -> Color {
        switch action {
        case .create: return .green
        case .update: return .orange
        case .unchanged: return .secondary
        }
    }
}
