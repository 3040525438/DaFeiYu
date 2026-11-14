import SwiftUI

/// 锁屏界面（D63）：口令 + Face ID；错误与冷却提示都来自数据层。
@MainActor
struct AppLockView: View {
    @ObservedObject var lock: AppLockController
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 40)

            DFCharacterMark(size: 76)

            VStack(spacing: 6) {
                Text("大肥鱼已锁定")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DFColor.ink)
                Text("口令与 Face ID 都只在本机校验")
                    .font(.system(size: 12))
                    .foregroundStyle(DFColor.inkMuted)
            }

            SecureField("输入口令", text: $lock.passcode)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .focused($focus)
                .padding(12)
                .background(DFColor.primarySoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 40)
                .submitLabel(.go)
                .onSubmit { Task { await lock.unlockWithPasscode() } }

            if let message = lock.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                Task { await lock.unlockWithPasscode() }
            } label: {
                Text("解锁")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(DFColor.primary)
            .padding(.horizontal, 40)

            if lock.biometricsAvailable {
                Button {
                    Task { await lock.unlockWithBiometrics() }
                } label: {
                    Label("使用 Face ID", systemImage: "faceid")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(DFColor.primary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DFColor.canvas.ignoresSafeArea())
        .task {
            focus = !lock.biometricsAvailable
            if lock.biometricsAvailable {
                await lock.unlockWithBiometrics()
            }
        }
    }
}
