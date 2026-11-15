import SwiftUI
import DFCore

@main
@MainActor
struct DaFeiYuApp: App {
    @StateObject private var bootstrap: AppBootstrap
    /// N-07：后台刷新（必须在启动早期注册）
    private let background: BackgroundRefreshService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let holder = ContainerHolder()
        let service = BackgroundRefreshService(holder: holder)
        service.register()
        self.background = service
        _bootstrap = StateObject(wrappedValue: AppBootstrap(holder: holder))
    }

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
            .onChange(of: scenePhase) { _, phase in
                // 进入后台时安排下一次补算；回到前台不主动排，避免浪费配额
                if phase == .background {
                    background.schedule()
                }
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
    private let holder: ContainerHolder

    init(holder: ContainerHolder = ContainerHolder()) {
        self.holder = holder
    }

    func start() async {
        guard !started else { return }
        started = true

        // 环境只由构建配置决定；失败即 fail closed，不建容器、不开库、不读 Keychain。
        let identity: EnvironmentIdentity
        do {
            identity = try EnvironmentIdentity.resolve(
                info: Bundle.main.infoDictionary ?? [:],
                actualBundleID: Bundle.main.bundleIdentifier
            )
        } catch {
            self.container = nil
            self.errorTitle = "环境校验未通过"
            self.errorMessage = EnvironmentDiagnostics.text(
                error: error,
                bundleID: Bundle.main.bundleIdentifier,
                dataRoot: try? FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: false
                ),
                keychainService: nil
            )
            self.started = false
            return
        }

        do {
            let container = try AppContainer(identity: identity)

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
            // 后台任务回调在系统线程，通过 holder 拿装配好的容器
            holder.set(container)
            Task {
                await container.bootstrap()
                // D09：启动时补一次自动备份检查（每日一次完整备份由策略保证）
                _ = try? await container.backupScheduler.runIfDue()
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
