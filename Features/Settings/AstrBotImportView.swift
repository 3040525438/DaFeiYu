import SwiftUI
import UniformTypeIdentifiers
import DFCore
import DFData

/// AstrBot 迁移（D38 / D39 / D40）：
/// 选目录 → 预演（完整映射后回滚）→ 正式导入 → 批次与待处理区可查、可回滚。
@MainActor
struct AstrBotImportView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var showFolderPicker = false
    @State private var sourceRoot: URL?
    @State private var preview: AstrBotImportReport?
    @State private var result: AstrBotImportReport?
    @State private var batches: [AstrBotBatchSummary] = []
    @State private var pending: [AstrBotPendingItem] = []
    @State private var pendingBatchID: String?
    @State private var busy = false
    @State private var message: String?
    @State private var showConfirmImport = false
    @State private var showConfirmRollback = false
    @State private var rollbackCandidate: String?
    /// 覆盖式导入：先清掉上一次导入写入的数据，避免重复累积
    @State private var replacePreviousImports = true
    /// 用导入的人格替换当前核心人格（占位人格无论开关都会自动替换）
    @State private var replaceCorePersona = true
    /// 导入后只保留导入的会话（删除现有非导入会话与消息）
    @State private var pruneExistingConversations = false

    var body: some View {
        List {
            Section {
                Button {
                    showFolderPicker = true
                } label: {
                    Label(sourceRoot == nil ? "选择 AstrBot 数据目录" : "重新选择目录", systemImage: "folder")
                }
                if let sourceRoot {
                    Text(sourceRoot.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // iOS 的文件夹选择器在部分系统版本上"点进去就没有确认按钮"，这里提供固定目录入口，
                // 用爱思助手把整个数据目录拖进 App 沙盒 Documents 即可，完全绕开系统选择器。
                Button {
                    if let url = sandboxSourceURL {
                        applySource(url)
                    } else {
                        message = "没找到沙盒内的数据目录：请用爱思助手把数据文件夹拖进本 App 沙盒的 Documents 下（文件夹名用 astrbot 或 _astrbot_review），再来点这里。"
                    }
                } label: {
                    Label("使用 App 内已放置的数据", systemImage: "internaldrive")
                }
                if let sandboxSourceURL {
                    Text("已发现沙盒数据：\(sandboxSourceURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("覆盖上次导入（先清理再写入）", isOn: $replacePreviousImports)
                Text("开启后只清理上一次导入带进来的消息/记忆/日记，你自己聊的内容不会被删除。关闭则为追加导入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("用导入的人格替换当前核心人格", isOn: $replaceCorePersona)
                Text("首启的占位人格无论如何都会被真实人格替换；这里决定是否也覆盖你已经改过的核心人格，旧版本会保留可回退。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("导入后只保留导入的会话", isOn: $pruneExistingConversations)
                Text("开启会把现有的非导入会话归档（聊天列表里不再显示，可在归档里恢复），不会删除消息、记忆与日记。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if preview == nil {
                    Button {
                        Task { await runImport(dryRun: true) }
                    } label: {
                        Label("预演导入（不写数据）", systemImage: "eye")
                    }
                    .disabled(sourceRoot == nil || busy)
                }

                // 正式导入常驻显示，避免"只看到预演按钮"的误解；未预演时禁用并有说明
                Button {
                    showConfirmImport = true
                } label: {
                    Label("正式导入（写入数据）", systemImage: "tray.and.arrow.down.fill")
                }
                .disabled(sourceRoot == nil || busy || preview == nil)
                if preview == nil {
                    Text("正式导入需先完成一次预演，确认计数无误后再写入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text("导入只读副本：源文件先复制到 App 沙盒再解析，原始数据包不会被修改。无法识别的数据进入待处理区，不静默丢弃。若系统选择器无法确认文件夹，可用爱思助手把数据目录拖进本 App 沙盒 Documents，再点「使用 App 内已放置的数据」。")
            }

            if let report = result ?? preview {
                reportSection(report)
            }

            // 预演通过后把"正式导入"直接送到结果下方：
            // 预演只是预览、不写任何数据，必须再点正式导入才会真正写入。
            // 真机反馈：预演成功后用户不知道去哪确认导入，聊天记录没变。
            if let preview, preview.counts.coverageProblems.isEmpty {
                Section {
                    Button {
                        showConfirmImport = true
                    } label: {
                        Label("下一步：正式导入（写入聊天记录）", systemImage: "tray.and.arrow.down.fill")
                    }
                    Text("预演不写数据，所以聊天页还没有变化。点上面按钮并确认后，历史消息、记忆、人格才会真正写入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if batches.isEmpty {
                    Text("还没有导入批次")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(batches) { batch in
                        batchRow(batch)
                    }
                }
            } header: {
                Text("批次记录")
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pendingTitle(item.reasonCode))
                                .font(.system(size: 13, weight: .medium))
                            Text(item.rawJSON)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } header: {
                    Text("待处理区（\(pending.count)）")
                } footer: {
                    Text("这些数据保原始内容，等待你人工决定去向。")
                }
            }
        }
        .navigationTitle("AstrBot 迁移")
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .task { await reload() }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { outcome in
            switch outcome {
            case .success(let urls):
                if let url = urls.first {
                    applySource(url)
                }
            case .failure(let error):
                message = "选择目录失败：\(error.localizedDescription)"
            }
        }
        .alert("开始正式导入？", isPresented: $showConfirmImport) {
            Button("导入", role: .destructive) {
                Task { await runImport(dryRun: false) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("正式导入会写入会话、记忆、日记、人格与文档，并保留可回滚批次。\(pruneExistingConversations ? "已开启「只保留导入的会话」：现有非导入会话会被归档，可在归档中恢复。" : "")")
        }
        .alert("回滚这个批次？", isPresented: $showConfirmRollback) {
            Button("回滚", role: .destructive) {
                Task { await rollback() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除该批次导入的实体，导入前的数据不受影响。")
        }
    }

    // MARK: - 数据源

    /// App 沙盒 Documents 下的候选目录名（用户用爱思助手把整个 AstrBot 目录拖进来即可）
    private var sandboxCandidates: [URL] {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        return ["astrbot", "_astrbot_review", "AstrBot", "AstrBotData"].map {
            documents.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// 只有确实存在 `data/` 或 `diary/` 才认作有效数据目录，避免误选空文件夹
    private var sandboxSourceURL: URL? {
        let fm = FileManager.default
        return sandboxCandidates.first { url in
            guard fm.fileExists(atPath: url.path) else { return false }
            return fm.fileExists(atPath: url.appendingPathComponent("data").path)
                || fm.fileExists(atPath: url.appendingPathComponent("diary").path)
        }
    }

    private func applySource(_ url: URL) {
        sourceRoot = url
        preview = nil
        result = nil
        message = nil
    }

    private func reportSection(_ report: AstrBotImportReport) -> some View {
        let counts = report.counts
        return Section {
            row("状态", report.isDryRun ? "预演" : "正式")
            row("聊天", "新增 \(counts.messagesNew) / 重复 \(counts.messagesDuplicate) / 待处理 \(counts.messagesPending)")
            row("记忆", "新增 \(counts.memoriesNew) / 重复 \(counts.memoriesDuplicate) / 待处理 \(counts.memoriesPending)")
            row("日记", "新增 \(counts.diariesNew) / 重复 \(counts.diaryDuplicates) / 待处理 \(counts.diaryPending)")
            row("人格", "导入 \(counts.personaRowsImported) / 待处理 \(counts.personaPending)")
            row("关系档案", "新增 \(counts.companionMemoriesNew) / 重复 \(counts.companionMemoriesDuplicate) / 待处理 \(counts.companionMemoriesPending)")
            row("关系里程碑", "新增 \(counts.relationshipMilestonesNew) / 重复 \(counts.relationshipMilestonesDuplicate)")
            row("阶段提案", "待确认 \(counts.relationshipProposalsNew)")
            row("配置留档", "待处理 \(counts.configPending)（不自动套用）")
            row("文档", "新增 \(counts.documentsNew) / 待处理 \(counts.documentsPending)")
            row("待处理合计", "\(counts.pendingTotal)")
            if !counts.coverageProblems.isEmpty {
                ForEach(counts.coverageProblems, id: \.self) { problem in
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(report.isDryRun ? "预演结果" : "导入结果")
        }
    }

    private func batchRow(_ batch: AstrBotBatchSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(batch.isDryRun ? "预演" : "正式导入")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(batch.status)
                    .font(.caption2)
                    .foregroundStyle(batch.status == "succeeded" ? .green : .secondary)
            }
            Text(dateText(batch.startedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("消息 \(batch.counts.messagesNew) · 记忆 \(batch.counts.memoriesNew) · 日记 \(batch.counts.diariesNew)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let error = batch.error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button("待处理") {
                    Task { await loadPending(batch.id) }
                }
                .font(.caption)
                if !batch.isDryRun, batch.status == "succeeded" {
                    Button("回滚", role: .destructive) {
                        rollbackCandidate = batch.id
                        showConfirmRollback = true
                    }
                    .font(.caption)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func sources(for root: URL) -> AstrBotSourcePaths {
        func exists(_ relative: String) -> URL? {
            let url = root.appendingPathComponent(relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return AstrBotSourcePaths(
            chatMemoryDatabase: exists("data/plugin_data/chat_memory/chat_memory.db"),
            longTermMemoryDatabase: exists("diary/memory.db"),
            personaDatabase: exists("data/data_v4.db"),
            diaryDirectory: exists("diary"),
            lettersDirectory: exists("letters"),
            bookNotesDirectory: exists("books/notes"),
            companionLedgerJSON: exists("data/plugin_data/astrbot_plugin_private_companion/companions.json"),
            configJSON: exists("data/cmd_config.json")
        )
    }

    private func runImport(dryRun: Bool) async {
        guard let sourceRoot else { return }
        busy = true
        defer { busy = false }
        message = nil

        let accessed = sourceRoot.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceRoot.stopAccessingSecurityScopedResource() }
        }

        let paths = sources(for: sourceRoot)
        guard paths.hasAnySource else {
            message = "这个目录里没有找到可识别的 AstrBot 数据（chat_memory.db / diary / data_v4.db 等）"
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrbot-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            let options = AstrBotImportOptions(
                isDryRun: dryRun,
                stagingDirectory: staging,
                replacesCorePersona: replaceCorePersona,
                replacesPreviousImports: replacePreviousImports,
                prunesNonImportedConversations: pruneExistingConversations
            )
            let report = try await container.astrbotImporter.run(source: paths, options: options)
            if dryRun {
                preview = report
                message = report.counts.coverageProblems.isEmpty
                    ? "预演通过，可以正式导入。"
                    : "预演发现覆盖不一致，请先查看红字提示。"
            } else {
                result = report
                preview = nil
                message = "正式导入完成：批次 \(report.batchID)。\(report.counts.messagesNew) 条历史消息已写入，回到聊天页 → 会话列表可看到「AstrBot 迁移」会话（按首条消息日期命名）。"
            }
            await reload()
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func rollback() async {
        guard let batchID = rollbackCandidate else { return }
        busy = true
        defer { busy = false }
        do {
            let report = try await container.astrbotImporter.rollback(batchID: batchID, at: Clock.nowMillis())
            let total = report.deletedMessages + report.deletedConversations + report.deletedMemories
                + report.deletedDiaries + report.deletedPersonaItems + report.deletedPersonas
                + report.deletedPending + report.deletedIDMaps
            message = "已回滚：删除 \(total) 项，保留批次记录"
            await reload()
        } catch {
            message = "回滚失败：\(error.localizedDescription)"
        }
    }

    private func loadPending(_ batchID: String) async {
        do {
            pending = try await container.astrbotImporter.pendingItems(batchID: batchID, limit: 100)
            pendingBatchID = batchID
            if pending.isEmpty { message = "该批次没有待处理项" }
        } catch {
            message = error.localizedDescription
        }
    }

    private func reload() async {
        batches = (try? await container.astrbotImporter.batches(limit: 20)) ?? []
    }

    private func dateText(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: Double(millis) / 1000)
            .formatted(date: .numeric, time: .shortened)
    }

    private func pendingTitle(_ code: String) -> String {
        switch code {
        case "unknown_role": return "无法识别的角色"
        case "system_event": return "系统通知（不当作对话）"
        case "media_missing": return "图片/文件本体缺失"
        case "tool_record": return "工具调用记录"
        case "media_archive": return "媒体归档条目"
        case "invalid_timestamp": return "时间戳非法"
        case "empty_content": return "内容为空"
        case "invalid_day": return "日期非法"
        case "diary_date_conflict": return "同一天日记冲突"
        case "unrecognized_diary_file": return "无法识别的日记文件"
        case "persona_conflict": return "人格条目冲突"
        case "relationship_ledger": return "关系账本（待人工确认）"
        case "reply_target_missing": return "回复目标缺失"
        case "unsupported_content_kind": return "不支持的内容类型"
        default: return code
        }
    }
}
