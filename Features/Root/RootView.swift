import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lock = AppLockController()
    @State private var selection: Int = 0
    @State private var showOnboarding = false
    @State private var didBootstrap = false

    var body: some View {
        ZStack {
            tabs
            if lock.isLocked {
                AppLockView(lock: lock)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: lock.isLocked)
        .task { await bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            Task { await lock.handle(phase: phase) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .privacySettingsChanged)) { _ in
            Task { await lock.reload() }
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
        guard !didBootstrap else { return }
        didBootstrap = true
        let completed = (try? await container.settings.string(for: "onboarding.completed.v1")) == "1"
        if !completed {
            showOnboarding = true
        }
    }
}
