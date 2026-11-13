import SwiftUI

@main
@MainActor
struct DaFeiYuApp: App {
    @StateObject private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = bootstrap.container {
                    RootView()
                        .environmentObject(container)
                } else if let message = bootstrap.errorMessage {
                    StartupErrorView(title: bootstrap.errorTitle, message: message) {
                        _ = Task { @MainActor in
                            await bootstrap.start()
                        }
                    }
                } else {
                    ProgressView("正在打开本地数据库…")
                }
            }
            .task {
                await bootstrap.start()
            }
        }
    }
}

/// 启动装配。数据库打不开时给出可读错误，而不是闪退。
@MainActor
final class AppBootstrap: ObservableObject {
    @Published private(set) var container: AppContainer?
    @Published private(set) var errorTitle: String = "本地数据库无法打开"
    @Published private(set) var errorMessage: String?

    private var started = false

    func start() async {
        guard !started else { return }
        started = true

        let environment = AppEnvironment.resolve(bundleID: Bundle.main.bundleIdentifier)

        do {
            let container = try AppContainer(environment: environment)

            // 升级失败：数据库已整体回滚到旧结构，保持原样，不进入业务界面，
            // 也不允许任何写入；只展示恢复提示与"重试"入口。
            if let failure = container.database.migrationFailureReason {
                self.container = nil
                self.errorTitle = "数据库升级未完成"
                self.errorMessage = """
                \(failure)

                原数据库已完整回滚到升级前的状态，未做任何修改。
                请先恢复最近一次已验证的备份，或点击"重试"再次执行升级。
                """
                self.started = false
                return
            }

            self.container = container
            self.errorMessage = nil
            Task {
                await container.bootstrap()
            }
        } catch {
            self.errorTitle = "本地数据库无法打开"
            self.errorMessage = error.localizedDescription
            self.started = false
        }
    }
}

@MainActor
struct StartupErrorView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}
