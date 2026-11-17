import XCTest
@testable import DFCore

/// AstrBot 迁移的开场对话示例格式化（P0 人格继承）。
/// 硬规则：只排版不改写；解析失败原样保留；空内容返回 nil。
final class BeginDialogsFormatterTests: XCTestCase {
    func testFormatsUserRoleDialogs() {
        let raw = #"[{"role":"user","content":"在吗"},{"role":"ai","content":"在的，怎么啦？"}]"#
        let result = BeginDialogsFormatter.format(raw)

        XCTAssertEqual(result, "用户：在吗\n你：在的，怎么啦？")
    }

    func testAssistantRoleAlsoMapsToSelf() {
        let raw = #"[{"role":"user","content":"早上好"},{"role":"assistant","content":"早呀"}]"#
        let result = BeginDialogsFormatter.format(raw)

        XCTAssertEqual(result, "用户：早上好\n你：早呀")
    }

    func testCustomSelfLabel() {
        let raw = #"[{"role":"user","content":"嗨"},{"role":"bot","content":"来啦"}]"#
        let result = BeginDialogsFormatter.format(raw, selfLabel: "大肥鱼")

        XCTAssertEqual(result, "用户：嗨\n大肥鱼：来啦")
    }

    func testInvalidJSONReturnsRawTextUntouched() {
        let raw = "这不是 JSON，只是一段原有的开场白文本。"
        let result = BeginDialogsFormatter.format(raw)

        XCTAssertEqual(result, raw, "解析失败必须原样保留，不能丢弃或摘要")
    }

    func testEmptyAndBlankInputsReturnNil() {
        XCTAssertNil(BeginDialogsFormatter.format(""))
        XCTAssertNil(BeginDialogsFormatter.format("   \n  "))
        XCTAssertNil(BeginDialogsFormatter.format("[]"), "空数组没有任何对话内容")
    }

    func testContentIsNeverRewritten() throws {
        // 对话内容里的换行、标点必须逐字保留
        let content = "今天有点累……\n想聊聊。"
        let data = try JSONSerialization.data(withJSONObject: [
            ["role": "user", "content": content]
        ])
        let raw = String(data: data, encoding: .utf8)!

        let result = BeginDialogsFormatter.format(raw)
        XCTAssertEqual(result, "用户：\(content)")
    }
}
