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
                    StartupErrorView(message: message) {
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
    @Published private(set) var errorMessage: String?

    private var started = false

    func start() async {
        guard !started else { return }
        started = true

        let environment = AppEnvironment.resolve(bundleID: Bundle.main.bundleIdentifier)

        do {
            let container = try AppContainer(environment: environment)
            self.container = container
            self.errorMessage = nil
            Task {
                await container.bootstrap()
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.started = false
        }
    }
}

@MainActor
struct StartupErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("本地数据库无法打开")
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
