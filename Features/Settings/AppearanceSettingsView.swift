import SwiftUI
import DFCore

/// D65：外观设置入口（设置页）。
///
/// 实际选项复用聊天页的 `ThemeSettingsSheet`，避免两处维护同一组枚举；
/// 保存后写入 `ChatThemeStoring` 并广播 `.chatThemeChanged`，
/// 由 `RootView` 立即应用明暗模式，聊天页下次出现时重载背景 / 气泡 / 字号。
@MainActor
struct AppearanceSettingsView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var theme: ChatTheme = .default
    @State private var showSheet = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("明暗模式", value: appearanceText)
                LabeledContent("主题", value: themeText)
                LabeledContent("聊天背景", value: backgroundText)
                LabeledContent("气泡", value: bubbleText)
                LabeledContent("字号", value: String(format: "%.0f%%", theme.fontScale * 100))
                LabeledContent("头像", value: avatarText)
            } header: {
                Text("当前外观")
            } footer: {
                Text("明暗模式立即对整个 App 生效；聊天背景、气泡与字号在回到聊天页时生效。")
            }

            Section {
                Button("调整外观") {
                    showSheet = true
                }
                Button("恢复默认外观", role: .destructive) {
                    Task { await reset() }
                }
            }
            if let message {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .sheet(isPresented: $showSheet) {
            ThemeSettingsSheet(
                theme: theme,
                onSave: { updated in
                    Task { await save(updated) }
                },
                onReset: {
                    Task { await reset() }
                }
            )
        }
    }

    private var appearanceText: String {
        switch theme.appearance {
        case "light": return "浅色"
        case "dark": return "深色"
        default: return "跟随系统"
        }
    }

    private var themeText: String {
        switch theme.themeID {
        case "warm": return "暖调"
        case "night": return "夜间"
        default: return "经典"
        }
    }

    private var backgroundText: String {
        switch theme.background {
        case "plain": return "纯净"
        case "dark": return "暗色"
        default: return "奶油"
        }
    }

    private var bubbleText: String {
        theme.bubbleStyle == "plain" ? "纯文字" : "气泡"
    }

    private var avatarText: String {
        theme.avatarStyle == "initial" ? "文字" : "鱼形"
    }

    private func reload() async {
        theme = (try? await container.chatTheme.load()) ?? .default
    }

    private func save(_ updated: ChatTheme) async {
        do {
            try await container.chatTheme.save(updated)
            theme = updated.normalized()
            NotificationCenter.default.post(name: .chatThemeChanged, object: nil)
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }

    private func reset() async {
        do {
            theme = try await container.chatTheme.reset()
            NotificationCenter.default.post(name: .chatThemeChanged, object: nil)
            message = "已恢复默认外观"
        } catch {
            message = "恢复失败：\(error.localizedDescription)"
        }
    }
}
