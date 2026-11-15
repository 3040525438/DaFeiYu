import SwiftUI
import DFCore

/// 诊断与存储（W10-3 / D66、D70）。
///
/// 只展示计数与体积；导出文件由 `DiagnosticRedactor` 脱敏，不含正文。
struct DiagnosticsView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var report: DiagnosticReport?
    @State private var exportURL: URL?
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        List {
            healthSection
            storageSection
            countSection
            exportSection
        }
        .navigationTitle("诊断与存储")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var healthSection: some View {
        Section {
            if let report {
                LabeledContent("健康检查", value: report.healthy ? "通过" : "异常")
                if let free = report.freeBytes {
                    LabeledContent("可用空间", value: StorageUsage.humanReadable(free))
                }
                if report.isLowOnSpace {
                    Text("可用空间偏低，建议清理备份或附件。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(report.healthNotes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(isWorking ? "检查中…" : "尚未生成报告")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("设备状态")
        }
    }

    private var storageSection: some View {
        Section {
            if let report {
                ForEach(report.storage.items) { item in
                    LabeledContent(item.title, value: StorageUsage.humanReadable(item.bytes))
                }
                LabeledContent("合计", value: StorageUsage.humanReadable(report.storage.totalBytes))
            }
        } header: {
            Text("存储分类")
        } footer: {
            Text("只统计本地数据库、附件与备份的占用，不会自动删除任何数据。")
        }
    }

    private var countSection: some View {
        Section {
            if let report, !report.counts.isEmpty {
                ForEach(report.counts.keys.sorted(), id: \.self) { key in
                    LabeledContent(displayName(key), value: "\(report.counts[key] ?? 0)")
                }
            } else {
                Text("暂无数据")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("记录计数")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                Task { await export() }
            } label: {
                Label("生成并分享诊断包", systemImage: "square.and.arrow.up")
            }
            .disabled(isWorking)

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("分享诊断文件", systemImage: "doc.text")
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("诊断包仅含版本、计数、体积与健康结论，密钥与账号已在导出前脱敏。")
        }
    }

    // MARK: - 动作

    private func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        report = await container.diagnostics.buildReport()
    }

    private func export() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let current = report ?? (await container.diagnostics.buildReport())
        report = current
        do {
            exportURL = try container.diagnostics.write(current)
            message = "已生成：\(DiagnosticExporter.fileName(at: current.generatedAt))"
        } catch {
            message = "生成失败：\(error.localizedDescription)"
        }
    }

    private func displayName(_ key: String) -> String {
        switch key {
        case "conversations": return "会话"
        case "messages": return "消息"
        case "memories": return "记忆"
        case "diary_entries": return "日记"
        case "personas": return "人格"
        case "attachments": return "附件"
        case "proactive_messages": return "主动消息"
        case "proposals": return "待确认提案"
        case "astrbot_import_pending": return "迁移待处理"
        default: return key
        }
    }
}
