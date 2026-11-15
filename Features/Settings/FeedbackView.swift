import SwiftUI
import UIKit
import DFCore

/// D70：反馈入口。生成可分享 / 可复制的报告，只含版本与计数，不含任何正文。
@MainActor
struct FeedbackView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var category: FeedbackCategory = .bug
    @State private var detail: String = ""
    @State private var messageCount: Int?
    @State private var attachmentCount: Int?
    @State private var copied = false

    private var snapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            systemVersion: "iOS \(UIDevice.current.systemVersion)",
            schemaVersion: container.schemaVersion,
            messageCount: messageCount,
            attachmentCount: attachmentCount,
            memoryCount: nil
        )
    }

    private var report: FeedbackReport {
        FeedbackReportBuilder.make(category: category, detail: detail, snapshot: snapshot)
    }

    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $category) {
                    ForEach(FeedbackCategory.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("反馈类型")
            }

            Section {
                TextEditor(text: $detail)
                    .frame(minHeight: 140)
                Text("\(min(detail.count, FeedbackReportBuilder.maxDetailLength))/\(FeedbackReportBuilder.maxDetailLength)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("发生了什么")
            } footer: {
                Text("请描述操作步骤与预期结果；不要粘贴密钥或他人隐私。")
            }

            Section {
                Text(report.body)
                    .font(.caption)
                    .textSelection(.enabled)
            } header: {
                Text("报告预览")
            } footer: {
                Text(FeedbackReportBuilder.privacyNotice)
            }

            Section {
                ShareLink(item: report.body) {
                    Label("分享报告", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = report.body
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制报告", systemImage: "doc.on.doc")
                }
            }
        }
        .navigationTitle("反馈")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCounts() }
    }

    private func loadCounts() async {
        guard let report = try? container.integrityChecker.run() else { return }
        messageCount = report.messageCount
        attachmentCount = report.attachmentCount
    }
}
