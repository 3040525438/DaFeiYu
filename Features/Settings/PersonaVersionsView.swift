import SwiftUI
import DFCore
import DFData

/// 核心人格：查看、编辑、版本回退（D30 / D07）。
///
/// 设计边界（与产品约束一致）：
/// - 核心人格**不会**被 AI 自动修改；这里只接受用户主动保存；
/// - 每次保存都会生成一个版本快照，可随时回退；
/// - 回退本身也会再生成一个版本，历史不会丢失。
@MainActor
struct PersonaVersionsView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let personaID: String

    @State private var name = ""
    @State private var prompt = ""
    @State private var versions: [PersonaVersion] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var message: String?
    @State private var errorText: String?
    @State private var pendingRestore: PersonaVersion?

    var body: some View {
        Form {
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(DFColor.primaryDeep)
                }
            }
            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(DFColor.danger)
                }
            }

            Section {
                TextField("名称", text: $name)
                TextEditor(text: $prompt)
                    .frame(minHeight: 200)
                    .font(.system(size: 13))
            } header: {
                Text("当前核心人格")
            } footer: {
                Text("只有你主动保存才会修改核心人格；保存后自动生成新版本，可随时回退。AI 不会自动改写这里。")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text(isSaving ? "正在保存…" : "保存为新版本")
                        Spacer()
                        if isSaving { ProgressView() }
                    }
                }
                .disabled(isSaving || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section {
                if isLoading {
                    ProgressView()
                } else if versions.isEmpty {
                    Text("还没有版本记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(versions.sorted { $0.version > $1.version }) { version in
                        versionRow(version)
                    }
                }
            } header: {
                Text("历史版本")
            } footer: {
                Text("回退会先记录当前状态，再把选中的版本写回；因此回退也不会丢失任何东西。")
            }
        }
        .navigationTitle("核心人格")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog(
            "回退到这个版本？",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingRestore {
                Button("回退到 v\(pendingRestore.version)", role: .destructive) {
                    Task { await restore(pendingRestore) }
                }
            }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("当前内容会先被记录为一个版本，然后写回所选版本的内容。")
        }
    }

    private func versionRow(_ version: PersonaVersion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("v\(version.version)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Text(version.changedBy == "user" ? "你" : version.changedBy)
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
                Spacer()
                Text(Self.timeText(version.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.inkMuted)
            }
            if !version.changeReason.isEmpty {
                Text(version.changeReason)
                    .font(.system(size: 11))
                    .foregroundStyle(DFColor.inkMuted)
            }
            Button("回退到此版本") {
                pendingRestore = version
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 数据

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let persona = try await container.personas.corePersona(), persona.id == personaID {
                name = persona.name
            }
            prompt = (try await container.personas.coreSystemPrompt()) ?? ""
            versions = try await container.personaGrowth.versions(personaID: personaID)
            errorText = nil
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let version = try await container.personaGrowth.updateCorePrompt(
                personaID: personaID,
                name: name,
                systemPrompt: prompt
            )
            message = "已保存为 v\(version.version)"
            await reload()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }

    private func restore(_ version: PersonaVersion) async {
        do {
            let restored = try await container.personaGrowth.restore(
                personaID: personaID,
                version: version.version
            )
            pendingRestore = nil
            message = "已回退到 v\(version.version)，当前为 v\(restored.version)"
            await reload()
        } catch {
            errorText = "回退失败：\(error.localizedDescription)"
        }
    }

    private static func timeText(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}
