import SwiftUI
import DFCore
import DFData

/// 诊断与存储（W10-3 / D66、D67、D70）。
///
/// 只展示计数与体积；导出文件由 `DiagnosticRedactor` 脱敏，不含正文。
/// 升级记录（D67）来自 `upgrade_records` 表，供升级失败后追溯，不提供任何伪造入口。
struct DiagnosticsView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var report: DiagnosticReport?
    @State private var exportURL: URL?
    @State private var isWorking = false
    @State private var message: String?

    /// 升级记录：nil 表示尚未读取完成，用于区分「加载中」与「空记录」
    @State private var upgradeRecords: [UpgradeRecordService.Record]?
    @State private var upgradeError: String?
    @State private var isLoadingUpgrades = false

    var body: some View {
        List {
            healthSection
            upgradeSection
            storageSection
            countSection
            exportSection
        }
        .navigationTitle("诊断与存储")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
            await loadUpgrades()
        }
        .refreshable {
            await refresh()
            await loadUpgrades()
        }
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

    /// D67：升级审计记录，按开始时间倒序展示最近 20 条。
    private var upgradeSection: some View {
        Section {
            if let upgradeError {
                Text(upgradeError)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
                Button("重新读取") {
                    Task { await loadUpgrades() }
                }
                .font(DFFont.caption)
                .disabled(isLoadingUpgrades)
            }

            if let records = upgradeRecords {
                if records.isEmpty {
                    Text("还没有升级记录")
                        .font(DFFont.body)
                        .foregroundStyle(DFColor.inkMuted)
                } else {
                    ForEach(records) { record in
                        upgradeRow(record)
                    }
                }
            } else if upgradeError == nil {
                Text("读取中…")
                    .font(DFFont.body)
                    .foregroundStyle(DFColor.inkMuted)
            }
        } header: {
            Text("升级记录")
        } footer: {
            Text("按开始时间倒序展示最近 20 次升级尝试，记录来自本地数据库；不会伪造升级或记录。")
                .font(DFFont.caption)
        }
    }

    private func upgradeRow(_ record: UpgradeRecordService.Record) -> some View {
        VStack(alignment: .leading, spacing: DFSpacing.xs) {
            HStack(spacing: DFSpacing.s) {
                Text(Self.timeText(record.startedAt))
                    .font(DFFont.timestamp)
                    .foregroundStyle(DFColor.inkMuted)
                Spacer(minLength: DFSpacing.s)
                Text(record.status.displayName)
                    .font(DFFont.caption)
                    .foregroundStyle(statusColor(record.status))
            }

            Text("\(versionText(record.fromVersion)) → \(versionText(record.toVersion))")
                .font(DFFont.body)
                .foregroundStyle(DFColor.ink)

            if let error = record.error, !error.isEmpty {
                Text("失败原因：\(error)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
            }

            if record.status == .running && !record.isFinished {
                Text("仍在进行；若长时间未结束，请重启 App 后在诊断页复查。")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.warning)
            }
        }
        .padding(.vertical, DFSpacing.xs)
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
        // `??` 右侧是 autoclosure，不能直接放 await
        let current: DiagnosticReport
        if let report {
            current = report
        } else {
            current = await container.diagnostics.buildReport()
        }
        report = current
        do {
            exportURL = try container.diagnostics.write(current)
            message = "已生成：\(DiagnosticExporter.fileName(at: current.generatedAt))"
        } catch {
            message = "生成失败：\(error.localizedDescription)"
        }
    }

    /// D67：读取最近 20 条升级记录；失败时只提示，不静默当空态。
    private func loadUpgrades() async {
        guard !isLoadingUpgrades else { return }
        isLoadingUpgrades = true
        defer { isLoadingUpgrades = false }
        do {
            upgradeRecords = try await container.upgrades.recent(limit: 20)
            upgradeError = nil
        } catch {
            upgradeError = "读取升级记录失败：\(error.localizedDescription)"
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

    // MARK: - 升级记录文案

    private func statusColor(_ status: UpgradeAuditStatus) -> Color {
        switch status {
        case .running: return DFColor.primary
        case .succeeded: return DFColor.success
        case .failed: return DFColor.danger
        case .rolledBack: return DFColor.warning
        }
    }

    /// `none` 是 UpgradeGuard 对「全新库 / 读不到版本」的标记，展示时翻译成易读文案。
    private func versionText(_ version: String) -> String {
        version == UpgradeGuard.unknownVersion ? "全新安装" : version
    }

    private static func timeText(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Clock.date(fromMillis: millis))
    }
}
