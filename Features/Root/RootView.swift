import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var selection: Int = 0

    var body: some View {
        TabView(selection: $selection) {
            ChatView(container: container) {
                selection = 1
            }
            .tabItem {
                Label("聊天", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(0)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(1)
        }
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
}
