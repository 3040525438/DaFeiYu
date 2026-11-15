import XCTest
@testable import DFCore

/// D65：外观设置中的明暗模式（跟随系统 / 浅色 / 深色）与旧数据兼容。
final class ChatThemeAppearanceTests: XCTestCase {

    func testDefaultAppearanceFollowsSystem() {
        XCTAssertEqual(ChatTheme.default.appearance, "system")
        XCTAssertTrue(ChatTheme.appearances.contains(ChatTheme.default.appearance))
    }

    func testUnknownAppearanceFallsBackToSystem() {
        var theme = ChatTheme.default
        theme.appearance = "neon"
        XCTAssertEqual(theme.normalized().appearance, "system")
    }

    func testKnownAppearancesPreserved() {
        for value in ChatTheme.appearances {
            var theme = ChatTheme.default
            theme.appearance = value
            XCTAssertEqual(theme.normalized().appearance, value)
        }
    }

    func testLegacyJSONWithoutAppearanceDecodesAsSystem() throws {
        // 旧版本存的是不含 appearance 字段的 JSON，不能判为坏数据
        let legacy = """
        {"themeID":"night","background":"dark","bubbleStyle":"plain","fontScale":1.1,"avatarStyle":"initial"}
        """
        let decoded = try JSONDecoder().decode(ChatTheme.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.themeID, "night")
        XCTAssertEqual(decoded.appearance, "system")
    }

    func testAppearanceSurvivesEncodingRoundTrip() throws {
        var theme = ChatTheme.default
        theme.appearance = "dark"
        let data = try JSONEncoder().encode(theme.normalized())
        let decoded = try JSONDecoder().decode(ChatTheme.self, from: data)
        XCTAssertEqual(decoded.appearance, "dark")
        XCTAssertEqual(decoded, theme)
    }
}
