import SwiftUI
import DFCore
import DFAI

/// 本地模型管理页（W5 / D58–D61）：登记、下载/续传、校验、删除文件。
///
/// 说明：本地推理内核仍未接入（N-18），本页只负责文件与下载任务，
/// 不宣称"本地模型可用于聊天"。
@MainActor
struct LocalModelsView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var manager = LocalModelManager()

    @State private var isAdding = false
    @State private var pendingRemove: LocalModelRecord?
    @State private var pendingDelete: LocalModelRecord?

    /// D61：独立备份勾选与结果提示
    @State private var backupSelection: Set<String> = []
    @State private var backupMessage: String?
    @State private var isBackingUp = false

    var body: some View {
        List {
            summarySection
            modelsSection
            backupSection
            noteSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .tint(DFColor.primary)
        .navigationTitle("本地模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            LocalModelEditor(manager: manager) { isAdding = false }
        }
        .confirmationDialog(
            "删除本地文件？",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            presenting: pendingRemove
        ) { model in
            Button("删除文件", role: .destructive) {
                Task { await manager.removeFile(id: model.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { model in
            Text("只删除「\(model.name)」的模型文件，登记记录保留，之后可以重新下载。")
        }
        .confirmationDialog(
            "删除登记记录？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { model in
            Button("删除登记", role: .destructive) {
                Task { await manager.deleteRecord(id: model.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { model in
            Text("这会移除「\(model.name)」的登记信息；已下载的文件不会被自动删除。")
        }
        .task {
            if !manager.isReady {
                manager.attach(
                    repository: container.localModels,
                    downloader: container.makeLocalModelDownloader()
                )
            }
            await manager.reload()
        }
    }

    // MARK: - D61 独立备份

    /// 当前勾选对应的备份计划（可用性、排除原因与体积都由纯逻辑给出）
    private var backupPlan: LocalModelBackupPlan {
        LocalModelBackupPolicy.plan(models: manager.models, selectedIDs: backupSelection)
    }

    private var backupSection: some View {
        Section {
            if manager.models.isEmpty {
                Text("还没有可备份的模型文件")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.models) { model in
                    backupRow(model)
                }

                HStack {
                    Text("已选 \(backupPlan.included.count) 个")
                        .font(.footnote)
                    Spacer()
                    Text(StorageUsage.humanReadable(backupPlan.totalBytes))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await runBackup() }
                } label: {
                    HStack(spacing: 6) {
                        if isBackingUp {
                            ProgressView()
                        }
                        Text(isBackingUp ? "正在备份…" : "备份所选模型")
                    }
                }
                .disabled(backupPlan.isEmpty || isBackingUp)

                if let backupMessage {
                    Text(backupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("独立备份")
        } footer: {
            Text("模型文件体积大且可重新下载，默认不进整体备份；勾选后会先重新校验 SHA-256 再复制。")
        }
    }

    private func backupRow(_ model: LocalModelRecord) -> some View {
        let compatibility = LocalModelBackupPolicy.compatibility(model)
        return Toggle(
            isOn: Binding(
                get: { backupSelection.contains(model.id) },
                set: { isOn in
                    if isOn {
                        backupSelection.insert(model.id)
                    } else {
                        backupSelection.remove(model.id)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.body)
                Text(
                    compatibility.isCompatible
                        ? "\(model.version.isEmpty ? "未标版本" : "v\(model.version)") · \(StorageUsage.humanReadable(model.byteSize))"
                        : compatibility.text
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .disabled(!compatibility.isCompatible)
    }

    private func runBackup() async {
        isBackingUp = true
        backupMessage = nil
        defer { isBackingUp = false }
        do {
            let result = try await container.localModelBackupService
                .backup(selectedIDs: backupSelection)
            backupMessage = "已备份 \(result.included.count) 个模型（\(StorageUsage.humanReadable(result.copiedBytes))）到 \(result.directory.lastPathComponent)"
            backupSelection = []
        } catch {
            backupMessage = ErrorDiagnoser.diagnose(error.localizedDescription).headline
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            LabeledContent("已登记", value: "\(manager.models.count) 个")
            LabeledContent("已就绪占用", value: StorageUsage.humanReadable(manager.readyBytes))
            if let message = manager.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("概览")
        }
    }

    private var modelsSection: some View {
        Section {
            if manager.models.isEmpty {
                Text("还没有登记本地模型。点右上角 + 填写下载地址、大小与 SHA-256。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.models) { model in
                    row(model)
                }
            }
        } header: {
            Text("模型文件")
        }
    }

    private var noteSection: some View {
        Section {
            Text("下载会先写入 .part 文件，校验和不一致时自动删除坏文件；中断后再次点“继续”即可断点续传。")
            Text("本地推理内核尚未接入，当前只管理模型文件与下载任务。")
        } header: {
            Text("说明")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func row(_ model: LocalModelRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.name)
                    .font(.body)
                Spacer()
                statusBadge(model)
            }

            Text(detailLine(model))
                .font(.caption)
                .foregroundStyle(.secondary)

            if manager.workingIDs.contains(model.id) || model.status == .downloading {
                ProgressView(value: model.progress)
                Text("\(StorageUsage.humanReadable(model.downloadedBytes)) / \(StorageUsage.humanReadable(model.byteSize))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = model
            } label: {
                Label("删除登记", systemImage: "trash")
            }

            if model.status != .notDownloaded {
                Button {
                    pendingRemove = model
                } label: {
                    Label("删除文件", systemImage: "folder.badge.minus")
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if model.status == .ready {
                Button {
                    Task { await manager.verify(id: model.id) }
                } label: {
                    Label("校验", systemImage: "checkmark.shield")
                }
                .tint(.green)
            } else {
                Button {
                    Task { await manager.download(id: model.id) }
                } label: {
                    Label(model.downloadedBytes > 0 ? "继续" : "下载", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }
        }
    }

    private func detailLine(_ model: LocalModelRecord) -> String {
        var parts: [String] = []
        if !model.family.isEmpty { parts.append(model.family) }
        if !model.quantization.isEmpty { parts.append(model.quantization) }
        parts.append(model.format.uppercased())
        parts.append(StorageUsage.humanReadable(model.byteSize))
        if model.wifiOnly { parts.append("仅 Wi-Fi") }
        return parts.joined(separator: " · ")
    }

    private func statusBadge(_ model: LocalModelRecord) -> some View {
        let (text, color): (String, Color) = {
            switch model.status {
            case .notDownloaded: return ("未下载", .secondary)
            case .downloading: return ("下载中", DFColor.primary)
            case .paused: return ("已暂停", .orange)
            case .ready: return ("已就绪", .green)
            case .failed: return ("失败", .red)
            }
        }()
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 新增登记

@MainActor
private struct LocalModelEditor: View {
    @ObservedObject var manager: LocalModelManager
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sourceURL = ""
    @State private var sha256 = ""
    @State private var sizeMB = ""
    @State private var format = "gguf"
    @State private var family = ""
    @State private var quantization = ""
    @State private var wifiOnly = true
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如：Qwen2.5 3B Q4_K_M", text: $name)
                }

                Section {
                    TextField("https://example.com/model.gguf", text: $sourceURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("下载地址")
                } footer: {
                    Text("必须是可直接下载模型文件的完整 http(s) 链接。")
                }

                Section {
                    TextField("64 位十六进制", text: $sha256)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("例如：2048", text: $sizeMB)
                        .keyboardType(.numberPad)
                } header: {
                    Text("完整性与大小")
                } footer: {
                    Text("SHA-256 与精确大小缺一不可：下载器不校验就不落正式文件（D60）。大小按 MB 填写。")
                }

                Section("规格（可选）") {
                    TextField("格式，如 gguf", text: $format)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("家族，如 qwen2", text: $family)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("量化，如 Q4_K_M", text: $quantization)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("仅 Wi-Fi 下载", isOn: $wifiOnly)
                } footer: {
                    Text("本地推理内核尚未接入，当前只管理模型文件与下载任务。")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("登记本地模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        errorText = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSHA = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedSize = sizeMB.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorText = "请填写名称"
            return
        }
        guard
            let url = URL(string: trimmedSource),
            let scheme = url.scheme,
            scheme.hasPrefix("http"),
            url.host != nil
        else {
            errorText = "下载地址必须是 http(s) 开头的完整 URL"
            return
        }
        guard trimmedSHA.count == 64, trimmedSHA.allSatisfy({ $0.isHexDigit }) else {
            errorText = "SHA-256 必须是 64 位十六进制"
            return
        }
        guard let megabytes = Int64(trimmedSize), megabytes > 0 else {
            errorText = "文件大小必须是大于 0 的整数（MB）"
            return
        }

        let resolvedFormat = trimmedFormat.isEmpty ? "gguf" : trimmedFormat.lowercased()
        let id = UUID().uuidString
        let now = Clock.nowMillis()
        let record = LocalModelRecord(
            id: id,
            name: trimmedName,
            family: family.trimmingCharacters(in: .whitespacesAndNewlines),
            quantization: quantization.trimmingCharacters(in: .whitespacesAndNewlines),
            format: resolvedFormat,
            fileRelPath: "\(id).\(resolvedFormat)",
            byteSize: megabytes * 1024 * 1024,
            sha256: trimmedSHA,
            sourceURL: trimmedSource,
            status: .notDownloaded,
            downloadedBytes: 0,
            wifiOnly: wifiOnly,
            createdAt: now,
            updatedAt: now
        )

        isSaving = true
        Task {
            let ok = await manager.register(record)
            isSaving = false
            if ok {
                dismiss()
                onClose()
            } else {
                errorText = manager.message
            }
        }
    }
}
