import XCTest
@testable import DFCore

/// 人格指纹纯逻辑测试（P-05 / P-11）
final class PersonaFingerprintTests: XCTestCase {
    private let items = [
        PersonaFingerprint.Item(key: "system_prompt", value: "我是 大肥鱼。\n我不是助手。", tier: "core"),
        PersonaFingerprint.Item(key: "Interest", value: "摄影", tier: "outer"),
        PersonaFingerprint.Item(key: "habit", value: "睡前聊天", tier: "pending")
    ]

    // 顺序无关
    func testFingerprintIsOrderIndependent() {
        let reversed = Array(items.reversed())
        XCTAssertEqual(
            PersonaFingerprint.compute(items: items, scope: .coreOuter).fingerprint,
            PersonaFingerprint.compute(items: reversed, scope: .coreOuter).fingerprint
        )
    }

    // 空白与大小写归一化
    func testFingerprintNormalizesWhitespaceAndCase() {
        let a = [PersonaFingerprint.Item(key: "Interest", value: "摄 影", tier: "outer")]
        let b = [PersonaFingerprint.Item(key: "interest", value: "摄 影", tier: "outer")]
        let c = [PersonaFingerprint.Item(key: "interest", value: "摄  影", tier: "outer")]
        let fa = PersonaFingerprint.compute(items: a, scope: .coreOuter).fingerprint
        XCTAssertEqual(fa, PersonaFingerprint.compute(items: b, scope: .coreOuter).fingerprint)
        XCTAssertEqual(fa, PersonaFingerprint.compute(items: c, scope: .coreOuter).fingerprint)
    }

    // pending 不参与任何范围
    func testPendingTierIsExcluded() {
        let withPending = PersonaFingerprint.compute(items: items, scope: .coreOuter)
        let withoutPending = PersonaFingerprint.compute(items: Array(items.prefix(2)), scope: .coreOuter)
        XCTAssertEqual(withPending.fingerprint, withoutPending.fingerprint)
        XCTAssertEqual(withPending.itemCount, 2)
    }

    // core 只含核心层，core_outer 含两层
    func testScopesCoverDifferentTiers() {
        let core = PersonaFingerprint.compute(items: items, scope: .core)
        let full = PersonaFingerprint.compute(items: items, scope: .coreOuter)
        XCTAssertEqual(core.itemCount, 1)
        XCTAssertEqual(full.itemCount, 2)
        XCTAssertNotEqual(core.fingerprint, full.fingerprint)
    }

    // 内容变化必须改变指纹
    func testContentChangeChangesFingerprint() {
        let before = PersonaFingerprint.compute(items: items, scope: .core).fingerprint
        var changed = items
        changed[0] = PersonaFingerprint.Item(key: "system_prompt", value: "我是大肥鱼。", tier: "core")
        XCTAssertNotEqual(before, PersonaFingerprint.compute(items: changed, scope: .core).fingerprint)
    }

    // 空人格也必须得到稳定的 64 位摘要
    func testEmptyPersonaIsStable() {
        let empty = PersonaFingerprint.compute(items: [], scope: .core)
        XCTAssertEqual(empty.itemCount, 0)
        XCTAssertEqual(empty.fingerprint.count, 64)
        XCTAssertEqual(empty.fingerprint, PersonaFingerprint.compute(items: [], scope: .core).fingerprint)
        XCTAssertEqual(empty.fingerprint, SHA256.hash("persona-fingerprint-v1\n"))
    }
}
