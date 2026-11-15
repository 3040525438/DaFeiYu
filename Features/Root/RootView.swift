import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lock = AppLockController()
    @State private var selection: Int = 0
    @State private var showOnboarding = false
    @State private var didBootstrap = false
    /// D65：界面外观模式（system / light / dark）
    @State private var appearanceMode: String = "system"

    var body: some View {
        ZStack {
            tabs
            if lock.isLocked {
                AppLockView(lock: lock)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: lock.isLocked)
        .preferredColorScheme(preferredScheme)
        .task { await bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            Task { await lock.handle(phase: phase) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .privacySettingsChanged)) { _ in
            Task { await lock.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatThemeChanged)) { _ in
            Task { await reloadAppearance() }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
            }
            .environmentObject(container)
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ChatView(container: container) {
                selection = 4
            }
            .tabItem {
                Label("聊天", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(0)

            MemoryView()
                .tabItem {
                    Label("记忆", systemImage: "books.vertical.fill")
                }
                .tag(1)

            GrowthView()
                .tabItem {
                    Label("成长", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(2)

            SpaceView(selection: $selection)
                .tabItem {
                    Label("空间", systemImage: "person.crop.circle.fill")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
        .tint(DFColor.primary)
        .overlay(alignment: .top) {
            if container.environment.isLab {
                Text("实验版 · 数据与正式版完全隔离")
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.9))
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                    .padding(.top, 2)
            }
        }
    }

    private func bootstrap() async {
        await lock.prepare(container)
        await reloadAppearance()
        guard !didBootstrap else { return }
        didBootstrap = true
        let completed = (try? await container.settings.string(for: "onboarding.completed.v1")) == "1"
        if !completed {
            showOnboarding = true
        }
    }

    /// D65：`nil` 交给系统决定，其余显式覆盖整个 App 的明暗。
    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func reloadAppearance() async {
        let theme = (try? await container.chatTheme.load()) ?? .default
        appearanceMode = theme.normalized().appearance
    }
}
