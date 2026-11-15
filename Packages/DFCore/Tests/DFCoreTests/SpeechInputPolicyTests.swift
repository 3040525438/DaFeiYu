import XCTest
@testable import DFCore

/// D16：语音转写跟随运行方式，只要涉及上传就必须先授权，拒绝后不偷偷上传。
final class SpeechInputPolicyTests: XCTestCase {

    func testOnDeviceNeverUploads() {
        let plan = SpeechInputPolicy.plan(
            preferred: .onDevice,
            deviceOnDeviceAvailable: true,
            consent: .undetermined
        )
        XCTAssertTrue(plan.allowed)
        XCTAssertFalse(plan.requiresUploadConsent)
        XCTAssertEqual(plan.mode, .onDevice)
        XCTAssertTrue(plan.explanation.contains("不会上传"))
        XCTAssertNil(plan.alternative)
    }

    func testOnDeviceUnsupportedFallsBackToText() {
        let plan = SpeechInputPolicy.plan(
            preferred: .onDevice,
            deviceOnDeviceAvailable: false,
            consent: .granted
        )
        XCTAssertFalse(plan.allowed)
        XCTAssertEqual(plan.mode, .unavailable)
        XCTAssertNotNil(plan.alternative)
    }

    func testCloudRequiresExplicitConsent() {
        let granted = SpeechInputPolicy.plan(preferred: .cloud, deviceOnDeviceAvailable: false, consent: .granted)
        XCTAssertTrue(granted.allowed)
        XCTAssertTrue(granted.requiresUploadConsent)
        XCTAssertTrue(granted.explanation.contains("上传"))

        let undetermined = SpeechInputPolicy.plan(preferred: .cloud, deviceOnDeviceAvailable: false, consent: .undetermined)
        XCTAssertFalse(undetermined.allowed)
        XCTAssertTrue(SpeechInputPolicy.needsConsentPrompt(undetermined))
    }

    func testCloudDeniedStopsWithoutUploading() {
        let plan = SpeechInputPolicy.plan(preferred: .cloud, deviceOnDeviceAvailable: false, consent: .denied)
        XCTAssertFalse(plan.allowed)
        XCTAssertTrue(plan.explanation.contains("拒绝"))
        XCTAssertNotNil(plan.alternative)
    }

    func testUnavailableModeAlwaysOffersText() {
        let plan = SpeechInputPolicy.plan(preferred: .unavailable, deviceOnDeviceAvailable: false, consent: .granted)
        XCTAssertFalse(plan.allowed)
        XCTAssertNotNil(plan.alternative)
        XCTAssertFalse(plan.requiresUploadConsent)
    }

    func testNoConsentPromptWhenAlreadyAllowed() {
        let plan = SpeechInputPolicy.plan(preferred: .cloud, deviceOnDeviceAvailable: false, consent: .granted)
        XCTAssertFalse(SpeechInputPolicy.needsConsentPrompt(plan))
    }

    func testTextAlternativeIsAlwaysAvailable() {
        XCTAssertFalse(SpeechInputPolicy.textAlternative.isEmpty)
    }

    // MARK: - 设置值解析（W9R）

    func testRunModeParsesKnownValues() {
        XCTAssertEqual(SpeechRunMode(settingValue: "on_device"), .onDevice)
        XCTAssertEqual(SpeechRunMode(settingValue: " cloud "), .cloud)
        XCTAssertEqual(SpeechRunMode(settingValue: "unavailable"), .unavailable)
    }

    func testRunModeFallsBackToOnDeviceForUnknownValues() {
        // 脏设置不能把音频推到云端
        XCTAssertEqual(SpeechRunMode(settingValue: nil), .onDevice)
        XCTAssertEqual(SpeechRunMode(settingValue: ""), .onDevice)
        XCTAssertEqual(SpeechRunMode(settingValue: "CLOUD"), .onDevice)
        XCTAssertEqual(SpeechRunMode(settingValue: "whatever"), .onDevice)
    }

    func testSelectableModesExcludeUnavailable() {
        XCTAssertEqual(SpeechRunMode.selectable, [.onDevice, .cloud])
        XCTAssertFalse(SpeechRunMode.selectable.contains(.unavailable))
    }
}
