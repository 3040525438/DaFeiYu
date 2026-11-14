import Foundation
import SwiftUI
import LocalAuthentication
import DFCore
import DFData

/// 锁屏状态机（D63）。
///
/// 只做三件事：把生命周期事件转成门禁决策、调用系统生物识别、把口令输入交给 `PrivacyGateService`。
/// 所有判定都在 DFCore/DFData 里，UI 不自行判断"该不该锁"。
@MainActor
final class AppLockController: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var settings = PrivacySettings.default
    @Published var passcode = ""
    @Published var errorMessage: String?
    @Published private(set) var biometricsAvailable = false

    private var service: PrivacyGateService?
    private var prepared = false

    func prepare(_ container: AppContainer) async {
        service = container.privacy
        guard !prepared else { return }
        prepared = true
        await reload()
        if settings.lockEnabled {
            isLocked = true
        }
        refreshBiometrics()
    }

    func reload() async {
        guard let service else { return }
        settings = (try? await service.settings()) ?? .default
        if !settings.lockEnabled {
            isLocked = false
        }
        refreshBiometrics()
    }

    func handle(phase: ScenePhase) async {
        guard let service else { return }
        switch phase {
        case .background:
            _ = try? await service.handleBackground()
        case .active:
            guard let decision = try? await service.handleForeground() else { return }
            if case .requiresUnlock = decision {
                isLocked = true
            }
            await reload()
        default:
            break
        }
    }

    func unlockWithPasscode() async {
        guard let service else { return }
        let code = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorMessage = "请输入口令"
            return
        }
        do {
            switch try await service.attemptPasscode(code) {
            case .unlocked:
                isLocked = false
                passcode = ""
                errorMessage = nil
            case .wrongPasscode(let remaining):
                errorMessage = "口令不正确，还可以尝试 \(remaining) 次"
                passcode = ""
            case .lockedOut(let until):
                errorMessage = "尝试次数过多，\(Self.timeText(until)) 后再试"
                passcode = ""
            case .notConfigured:
                isLocked = false
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlockWithBiometrics() async {
        guard let service else { return }
        let context = LAContext()
        context.localizedCancelTitle = "输入口令"
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁大肥鱼"
            )
            guard ok else { return }
            switch try await service.biometricUnlocked() {
            case .unlocked:
                isLocked = false
                errorMessage = nil
            case .notConfigured:
                errorMessage = "尚未启用 Face ID，请先输入口令"
            case .lockedOut, .wrongPasscode:
                break
            }
        } catch {
            // 用户取消或识别失败：留在锁屏，不额外记失败次数
        }
    }

    func lockNow() async {
        guard let service else { return }
        _ = try? await service.lockNow()
        isLocked = true
    }

    private func refreshBiometrics() {
        guard settings.lockEnabled, settings.biometricsEnabled else {
            biometricsAvailable = false
            return
        }
        let context = LAContext()
        biometricsAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: nil
        )
    }

    private static func timeText(_ millis: Int64) -> String {
        let seconds = max(Int((millis - Clock.nowMillis()) / 1000), 1)
        if seconds >= 60 {
            return "\(seconds / 60) 分钟"
        }
        return "\(seconds) 秒"
    }
}
