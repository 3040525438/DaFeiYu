import SwiftUI
import DFCore

/// 删除全部数据（D45）：先列清单，再逐字确认，并说明密钥销毁后果。
@MainActor
struct DataDeletionView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var plan: DataDeletionPlan?
    @State private var phrase = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showFinalConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if let plan {
                    Section {
                        ForEach(plan.items.filter { $0.count > 0 }) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                    Text(item.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(item.count)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DFColor.inkMuted)
                            }
                        }
                        if plan.totalCount == 0 {
                            Text("当前没有可删除的数据。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("将被删除（共 \(plan.totalCount) 项）")
                    }

                    Section {
                        Text(plan.keyLossWarning)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } header: {
                        Text("不可恢复")
                    }

                    Section {
                        TextField("逐字输入：\(DataDeletionPlan.confirmationPhrase)", text: $phrase)
                        Button("永久删除全部数据", role: .destructive) {
                            showFinalConfirm = true
                        }
                        .disabled(phrase != DataDeletionPlan.confirmationPhrase || busy)
                        if busy {
                            ProgressView()
                        }
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView("正在统计…")
                }
            }
            .navigationTitle("删除全部数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await loadPlan() }
            .alert("确认永久删除？", isPresented: $showFinalConfirm) {
                Button("删除", role: .destructive) {
                    Task { await deleteAll() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可撤销，建议先在「备份与恢复」创建一份备份。")
            }
        }
    }

    private func loadPlan() async {
        do {
            plan = try await container.privacy.deletionPlan()
        } catch {
            message = error.localizedDescription
        }
    }

    private func deleteAll() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await container.privacy.deleteAll(
                confirmation: DataDeletionPlan.confirmationPhrase
            )
            // 密钥一并销毁：既有备份从此无法解密
            try? container.backupKeys.deleteKey()
            phrase = ""
            await loadPlan()
            message = "已删除本机全部数据；既有备份文件因密钥销毁已不可解密。"
        } catch {
            message = error.localizedDescription
        }
    }
}
