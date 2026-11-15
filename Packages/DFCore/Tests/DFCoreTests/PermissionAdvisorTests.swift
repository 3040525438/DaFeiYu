import XCTest
@testable import DFCore

/// D69：按需申请、状态说明、拒绝后的替代方案与系统限制处理。
final class PermissionAdvisorTests: XCTestCase {

    func testNeverRequestsOnLaunch() {
        XCTAssertFalse(PermissionAdvisor.shouldRequestOnLaunch, "启动阶段不得提前申请任何权限")
    }

    func testNotDeterminedOffersRequestOnlyOnFirstUse() {
        let advice = PermissionAdvisor.advice(permission: .microphone, status: .notDetermined)
        XCTAssertEqual(advice.action, .request)
        XCTAssertFalse(advice.isUsable)
        XCTAssertTrue(PermissionAdvisor.shouldRequestOnFirstUse(.notDetermined))
        XCTAssertFalse(PermissionAdvisor.shouldRequestOnFirstUse(.denied))
    }

    func testGrantedAndLimitedAreUsableWithoutAction() {
        for status in [PermissionStatus.granted, .limited] {
            let advice = PermissionAdvisor.advice(permission: .notifications, status: status)
            XCTAssertEqual(advice.action, .none)
            XCTAssertTrue(advice.isUsable)
        }
    }

    func testDeniedPointsToSystemSettingsAndKeepsAlternative() {
        let advice = PermissionAdvisor.advice(permission: .notifications, status: .denied)
        XCTAssertEqual(advice.action, .openSettings)
        XCTAssertTrue(PermissionAdvisor.requiresSystemSettings(.denied))
        XCTAssertFalse(advice.alternative.isEmpty, "被拒绝后必须给出替代方案")
        XCTAssertFalse(advice.isUsable)
    }

    func testRestrictedDoesNotAskAgain() {
        let advice = PermissionAdvisor.advice(permission: .speechRecognition, status: .restricted)
        XCTAssertEqual(advice.action, .none)
        XCTAssertFalse(PermissionAdvisor.requiresSystemSettings(.restricted), "系统限制去设置也打不开")
        XCTAssertTrue(advice.explanation.contains("限制"))
    }

    func testEveryPermissionHasPurposeAndAlternative() {
        for permission in AppPermission.allCases {
            XCTAssertFalse(permission.purpose.isEmpty)
            XCTAssertFalse(permission.alternative.isEmpty)
            XCTAssertFalse(permission.displayName.isEmpty)
        }
    }

    func testNoPhotoPermissionRequired() {
        // 附件选择走系统 PHPicker，不需要相册权限，不应出现在申请清单里
        XCTAssertFalse(AppPermission.allCases.map(\.rawValue).contains("photo_library"))
    }

    func testAdvicesFollowFixedOrderAndFillMissingStatuses() {
        let advices = PermissionAdvisor.advices([.notifications: .granted])
        XCTAssertEqual(advices.map(\.permission), AppPermission.allCases)
        XCTAssertEqual(advices.first?.status, .granted)
        XCTAssertTrue(
            advices.dropFirst().allSatisfy { $0.status == .notDetermined },
            "未提供的状态按尚未询问处理"
        )
    }
}
