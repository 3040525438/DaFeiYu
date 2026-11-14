import SwiftUI
import DFCore

extension Notification.Name {
    /// 隐私设置发生变化（锁屏状态机据此刷新）
    static let privacySettingsChanged = Notification.Name("dafeiyu.privacy.settings.changed")
}

/// 隐私与安全（D63 / D59 / D45）
@MainActor
struct PrivacySettingsView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var settings = PrivacySettings.default
    @State private var consents: [PrivacyConsent] = []
    @State private var showPasscodeSheet = false
    @State private var showDeleteSheet = false
    @State private var message: String?

    private let delayOptions: [(String, Int)] = [
        ("立即锁定", 0),
        ("30 秒后", 30),
        ("1 分钟后", 60),
        ("5 分钟后", 300)
    ]

    var body: some View {
        Form {
            lockSection
            consentSection
            deletionSection
            if let message {
                Section {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("隐私与安全")
        .scrollContentBackground(.hidden)
        .background(DFColor.canvas)
        .task { await reload() }
        .sheet(isPresented: $showPasscodeSheet) {
            PasscodeSetupView { passcode in
                await configure(passcode)
            }
        }
        .sheet(isPresented: $showDeleteSheet) {
            DataDeletionView()
        }
    }

    // MARK: - 锁屏

    private var lockSection: some View {
        Section {
            Toggle("启用锁屏", isOn: Binding(
                get: { settings.lockEnabled },
                set: { enabled in
                    if enabled, settings.passcodeHash == nil {
                        showPasscodeSheet = true
                    } else {
                        var next = settings
                        next.lockEnabled = enabled
                        Task { await save(next) }
                    }
                }
            ))

            Button(settings.passcodeHash == nil ? "设置口令" : "修改口令") {
                showPasscodeSheet = true
            }

            Toggle("使用 Face ID 解锁", isOn: Binding(
                get: { settings.biometricsEnabled },
                set: { enabled in
                    var next = settings
                    next.biometricsEnabled = enabled
                    Task { await save(next) }
                }
            ))
            .disabled(!settings.lockEnabled)

            Picker("回到前台后", selection: Binding(
                get: { settings.lockDelaySeconds },
                set: { value in
                    var next = settings
                    next.lockDelaySeconds = value
                    Task { await save(next) }
                }
            )) {
                ForEach(delayOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .disabled(!settings.lockEnabled)

            Toggle("在多任务预览中隐藏内容", isOn: Binding(
                get: { settings.hideContentInSwitcher },
                set: { value in
                    var next = settings
                    next.hideContentInSwitcher = value
                    Task { await save(next) }
                }
            ))
        } header: {
            Text("锁屏")
        } footer: {
            Text("口令只保存加盐哈希；连续输错 \(settings.maxFailedAttempts) 次会锁定 \(settings.lockoutSeconds) 秒。密钥与口令都不会离开这台设备。")
        }
    }

    // MARK: - 授权记录

    private var consentSection: some View {
        Section {
            ForEach(PrivacyConsentKind.allCases, id: \.self) { kind in
                Toggle(isOn: consentBinding(kind)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("授权记录")
        } footer: {
            Text("随时可以撤销；撤销后对应功能会重新询问。云端模型默认关闭。")
        }
    }

    // MARK: - 删除

    private var deletionSection: some View {
        Section {
            Button("删除全部数据…", role: .destructive) {
                showDeleteSheet = true
            }
        } header: {
            Text("数据")
        } footer: {
            Text(DataDeletionPlan.keyLossWarningText)
        }
    }

    // MARK: - 行为

    private func consentBinding(_ kind: PrivacyConsentKind) -> Binding<Bool> {
        Binding(
            get: { consents.first { $0.kind == kind }?.granted ?? false },
            set: { granted in
                Task {
                    _ = try? await container.privacy.setConsent(kind, granted: granted)
                    await reload()
                }
            }
        )
    }

    private func reload() async {
        settings = (try? await container.privacy.settings()) ?? .default
        consents = (try? await container.privacy.consents()) ?? []
    }

    private func save(_ next: PrivacySettings) async {
        do {
            try await container.privacy.saveSettings(next)
            settings = next
            NotificationCenter.default.post(name: .privacySettingsChanged, object: nil)
        } catch {
            message = error.localizedDescription
        }
    }

    private func configure(_ passcode: String) async {
        do {
            try await container.privacy.configurePasscode(passcode, biometrics: settings.biometricsEnabled)
            await reload()
            NotificationCenter.default.post(name: .privacySettingsChanged, object: nil)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// 口令设置：两次输入一致且为 6 位数字。
@MainActor
private struct PasscodeSetupView: View {
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("新口令（6 位数字）", text: $first)
                        .keyboardType(.numberPad)
                    SecureField("再次输入", text: $second)
                        .keyboardType(.numberPad)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("口令只保存哈希，忘记后只能删除全部数据重来。")
                    }
                }
            }
            .navigationTitle("设置口令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(first.count != 6 || second.count != 6)
                }
            }
        }
    }

    private func save() {
        guard first == second else {
            error = "两次输入不一致"
            return
        }
        guard first.allSatisfy(\.isNumber) else {
            error = "口令只能是数字"
            return
        }
        Task {
            await onSave(first)
            dismiss()
        }
    }
}
