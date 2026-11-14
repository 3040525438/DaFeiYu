import XCTest
@testable import DFCore

/// W9：隐私门禁决策（锁定窗口、失败保护、前后台延迟）
final class PrivacyGateTests: XCTestCase {
    private let lockedSettings = PrivacySettings(
        lockEnabled: true,
        biometricsEnabled: true,
        passcodeHash: PrivacyGate.hashPasscode("123456"),
        lockDelaySeconds: 30,
        maxFailedAttempts: 3,
        lockoutSeconds: 60
    )

    func testDisabledGateAlwaysAllows() {
        let decision = PrivacyGate.decision(
            settings: .default,
            state: PrivacyGateState(isLocked: true),
            event: .appLaunch,
            at: 1_000
        )
        XCTAssertEqual(decision, .allowed, "未启用门禁时不应拦截")
    }

    func testLaunchRequiresUnlockWhenLocked() {
        let state = PrivacyGateState(isLocked: true)
        XCTAssertEqual(
            PrivacyGate.decision(settings: lockedSettings, state: state, event: .appLaunch, at: 1_000),
            .requiresUnlock(.launch)
        )
        let unlocked = PrivacyGateState(isLocked: false)
        XCTAssertEqual(
            PrivacyGate.decision(settings: lockedSettings, state: unlocked, event: .appLaunch, at: 1_000),
            .allowed
        )
    }

    func testForegroundDelayBoundary() {
        let background = PrivacyGate.enterBackground(PrivacyGateState(), at: 10_000)
        // 29 秒：未到延迟，允许
        XCTAssertEqual(
            PrivacyGate.decision(settings: lockedSettings, state: background, event: .foreground, at: 39_000),
            .allowed
        )
        // 30 秒：到点即锁
        XCTAssertEqual(
            PrivacyGate.decision(settings: lockedSettings, state: background, event: .foreground, at: 40_000),
            .requiresUnlock(.foreground)
        )
    }

    func testFailureLockoutWindow() {
        var state = PrivacyGateState(isLocked: true)
        state = PrivacyGate.registerFailure(state, settings: lockedSettings, at: 1_000)
        XCTAssertEqual(state.failedAttempts, 1)
        XCTAssertNil(state.lockedUntil)

        state = PrivacyGate.registerFailure(state, settings: lockedSettings, at: 1_100)
        state = PrivacyGate.registerFailure(state, settings: lockedSettings, at: 1_200)
        XCTAssertEqual(state.lockedUntil, 1_200 + 60_000, "达到上限后进入冷却窗口")
        XCTAssertEqual(state.failedAttempts, 0)

        XCTAssertEqual(
            PrivacyGate.decision(settings: lockedSettings, state: state, event: .unlockAttempt, at: 1_300),
            .lockedOut(until: 61_200),
            "冷却期内连正确口令也不放行"
        )
        XCTAssertEqual(
            PrivacyGate.decision(settings: lockedSettings, state: state, event: .unlockAttempt, at: 61_200),
            .requiresUnlock(.sensitiveAction)
        )
    }

    func testSuccessResetsState() {
        var state = PrivacyGateState(isLocked: true, failedAttempts: 2, lockedUntil: 9_999)
        state = PrivacyGate.registerSuccess(state, at: 5_000)
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.failedAttempts, 0)
        XCTAssertNil(state.lockedUntil)
        XCTAssertEqual(state.lastUnlockedAt, 5_000)
    }

    func testBiometricFailureNotCountedHere() {
        // 生物识别失败由系统负责重试，本层只在成功时清零
        let state = PrivacyGateState(isLocked: true, failedAttempts: 1)
        let decision = PrivacyGate.decision(
            settings: lockedSettings,
            state: state,
            event: .sensitiveAction,
            reason: .sensitiveAction,
            at: 1_000
        )
        XCTAssertEqual(decision, .requiresUnlock(.sensitiveAction))
        XCTAssertEqual(state.failedAttempts, 1, "决策函数不得隐式修改失败计数")
    }
}
