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
                Button {
                    Task { await runImport(dryRun: true) }
                } label: {
                    Label("预演导入（不写数据）", systemImage: "eye")
                }
                .disabled(sourceRoot == nil || busy)

                if preview != nil {
                    Button {
                        showConfirmImport = true
                    } label: {
                        Label("正式导入", systemImage: "tray.and.arrow.down.fill")
                    }
                    .disabled(busy)
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
                Text("导入只读副本：源文件先复制到 App 沙盒再解析，原始数据包不会被修改。无法识别的数据进入待处理区，不静默丢弃。")
            }

            if let report = result ?? preview {
                reportSection(report)
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
                sourceRoot = urls.first
                preview = nil
                result = nil
                message = nil
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
            Text("正式导入会写入会话、记忆、日记、人格与文档，并保留可回滚批次。")
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
            companionLedgerJSON: exists("data/plugin_data/astrbot_plugin_private_companion/companions.json")
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
            let options = AstrBotImportOptions(isDryRun: dryRun, stagingDirectory: staging)
            let report = try await container.astrbotImporter.run(source: paths, options: options)
            if dryRun {
                preview = report
                message = report.counts.coverageProblems.isEmpty
                    ? "预演通过，可以正式导入。"
                    : "预演发现覆盖不一致，请先查看红字提示。"
            } else {
                result = report
                preview = nil
                message = "正式导入完成：批次 \(report.batchID)"
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
