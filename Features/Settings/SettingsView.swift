import SwiftUI
import DFCore
import DFData
import DFAI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var configs: [ModelConfig] = []
    @State private var corePersonaName: String = ""
    @State private var corePrompt: String = ""
    @State private var isCreating = false
    @State private var editingConfig: ModelConfig?
    @State private var pendingDelete: ModelConfig?
    @State private var showDeleteConfirm = false
    @State private var busyConfigID: String?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                environmentSection
                modelSection
                personaSection
                maintenanceSection
                aboutSection
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isCreating, onDismiss: reloadAfterSheet) {
                ModelConfigEditor(container: container, existing: nil)
            }
            .sheet(item: $editingConfig, onDismiss: reloadAfterSheet) { config in
                ModelConfigEditor(container: container, existing: config)
            }
            .alert("删除模型配置？", isPresented: $showDeleteConfirm, presenting: pendingDelete) { config in
                Button("删除", role: .destructive) {
                    Task { await delete(config) }
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("只删除配置和对应的密钥，不会删除聊天记录。")
            }
            .task {
                await reload()
            }
        }
    }

    // MARK: - Sections

    private var environmentSection: some View {
        Section("运行环境") {
            LabeledContent("版本", value: container.environment.displayName)
            LabeledContent("Bundle ID", value: container.environment.bundleIdentifier)
            LabeledContent("数据库版本", value: container.schemaVersion)
            VStack(alignment: .leading, spacing: 4) {
                Text("数据目录").font(.footnote).foregroundStyle(.secondary)
                Text(container.dataRootPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private var modelSection: some View {
        Section {
            if configs.isEmpty {
                Text("还没有模型配置。点右上角 + 添加一个 OpenAI 兼容接口。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(configs) { config in
                    modelRow(config)
                }
            }
        } header: {
            Text("模型配置")
        } footer: {
            Text("密钥保存在系统 Keychain，不写入数据库，也不会随备份导出。")
        }
    }

    private func modelRow(_ config: ModelConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(config.name)
                if config.isDefault {
                    Text("默认")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                if busyConfigID == config.id {
                    ProgressView()
                }
            }
            Text(config.baseURL)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(config.modelID)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingConfig = config
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = config
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await test(config) }
            } label: {
                Label("测试", systemImage: "bolt")
            }
            .tint(.orange)

            if !config.isDefault {
                Button {
                    Task { await makeDefault(config) }
                } label: {
                    Label("设为默认", systemImage: "star")
                }
                .tint(.blue)
            }
        }
    }

    private var personaSection: some View {
        Section("核心人格") {
            LabeledContent("名称", value: corePersonaName.isEmpty ? "（未初始化）" : corePersonaName)
            DisclosureGroup("查看人格提示词") {
                Text(corePrompt.isEmpty ? "（暂无）" : corePrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("第一阶段只是占位人格；阶段二会用 AstrBot 的真实设定建立新版本，不会覆盖历史。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var maintenanceSection: some View {
        Section("数据自检") {
            Button("运行完整性检查") {
                Task { await runIntegrityCheck() }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            Text("大肥鱼 · 第一阶段（本地聊天与数据基础）")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("本版本不包含主动行为、记忆检索与备份恢复，这些在后续阶段实现。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func reloadAfterSheet() {
        Task { await reload() }
    }

    private func reload() async {
        do {
            configs = try await container.modelConfigs.all()
            let persona = try await container.personas.corePersona()
            corePersonaName = persona?.name ?? ""
            corePrompt = (try await container.personas.coreSystemPrompt()) ?? ""
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func test(_ config: ModelConfig) async {
        busyConfigID = config.id
        defer { busyConfigID = nil }

        do {
            let provider = try container.provider(for: config)
            guard let pingable = provider as? Pingable else {
                statusMessage = "当前接口类型不支持连通测试"
                return
            }
            let reply = try await pingable.ping()
            statusMessage = reply.isEmpty
                ? "连通成功（模型未返回内容）"
                : "连通成功：\(reply)"
        } catch {
            statusMessage = "连通失败：\(error.localizedDescription)"
        }
    }

    private func makeDefault(_ config: ModelConfig) async {
        do {
            try await container.modelConfigs.makeDefault(id: config.id)
            await reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func delete(_ config: ModelConfig) async {
        do {
            try await container.modelConfigs.delete(id: config.id)
            try? container.secureStore.delete(config.keyRef)
            pendingDelete = nil
            await reload()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func runIntegrityCheck() async {
        do {
            let report = try container.integrityChecker.run()
            var parts: [String] = []
            parts.append("数据库：\(report.databaseCheck)")
            parts.append("消息：\(report.messageCount) 条")
            parts.append("附件：\(report.attachmentCount) 个")
            if !report.missingAttachmentFiles.isEmpty {
                parts.append("缺失附件文件：\(report.missingAttachmentFiles.count) 个")
            }
            if !report.orphanAttachmentFiles.isEmpty {
                parts.append("未索引文件：\(report.orphanAttachmentFiles.count) 个")
            }
            statusMessage = parts.joined(separator: " · ")
        } catch {
            statusMessage = "自检失败：\(error.localizedDescription)"
        }
    }
}
