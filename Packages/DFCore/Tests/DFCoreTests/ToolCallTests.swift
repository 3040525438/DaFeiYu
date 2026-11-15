import XCTest
@testable import DFCore

/// D03：应用层工具调用兼容（文本协议 + 注册表校验，不依赖原生 function calling）。
final class ToolCallTests: XCTestCase {
    private var tools: [ToolDefinition] {
        [
            ToolDefinition(
                name: "search_memory",
                summary: "在长期记忆里检索",
                requiredArguments: ["query": .string],
                optionalArguments: ["limit": .number]
            ),
            ToolDefinition(
                name: "add_diary",
                summary: "写一条日记",
                requiredArguments: ["content": .string, "is_private": .boolean]
            )
        ]
    }

    private func block(_ json: String) -> String {
        "先想一下\n```tool\n\(json)\n```\n完成"
    }

    func testParsesValidCall() throws {
        let raw = block(#"{"name": "search_memory", "arguments": {"query": "考试", "limit": 3}}"#)
        let invocation = try ToolCallProtocol.parse(raw, tools: tools)
        XCTAssertEqual(invocation.name, "search_memory")
        XCTAssertEqual(invocation.string("query"), "考试")
        XCTAssertEqual(invocation.number("limit"), 3)
    }

    func testAcceptsToolKeyAsAlias() throws {
        let raw = block(#"{"tool": "add_diary", "arguments": {"content": "今天很累", "is_private": true}}"#)
        let invocation = try ToolCallProtocol.parse(raw, tools: tools)
        XCTAssertEqual(invocation.name, "add_diary")
        XCTAssertEqual(invocation.bool("is_private"), true)
    }

    func testPlainTextWithoutBlockIsNoToolCall() {
        XCTAssertThrowsError(try ToolCallProtocol.parse("今天想早点睡", tools: tools)) { error in
            XCTAssertEqual(error as? ToolCallError, .noToolCall)
        }
    }

    func testEmptyOutputThrows() {
        XCTAssertThrowsError(try ToolCallProtocol.parse("   ", tools: tools)) { error in
            XCTAssertEqual(error as? ToolCallError, .emptyOutput)
        }
    }

    func testEmptyBlockIsNoToolCall() {
        XCTAssertThrowsError(try ToolCallProtocol.parse("```tool\n\n```", tools: tools)) { error in
            XCTAssertEqual(error as? ToolCallError, .noToolCall)
        }
    }

    func testUnknownToolIsRejected() {
        let raw = block(#"{"name": "delete_everything", "arguments": {}}"#)
        XCTAssertThrowsError(try ToolCallProtocol.parse(raw, tools: tools)) { error in
            XCTAssertEqual(error as? ToolCallError, .unknownTool("delete_everything"))
        }
    }

    func testMissingRequiredArgumentIsRejected() {
        let raw = block(#"{"name": "search_memory", "arguments": {}}"#)
        XCTAssertThrowsError(try ToolCallProtocol.parse(raw, tools: tools)) { error in
            XCTAssertEqual(
                error as? ToolCallError,
                .missingArgument(tool: "search_memory", argument: "query")
            )
        }
    }

    func testUndeclaredArgumentIsRejected() {
        let raw = block(#"{"name": "search_memory", "arguments": {"query": "考试", "sql": "drop table"}}"#)
        XCTAssertThrowsError(try ToolCallProtocol.parse(raw, tools: tools)) { error in
            XCTAssertEqual(
                error as? ToolCallError,
                .unexpectedArgument(tool: "search_memory", argument: "sql")
            )
        }
    }

    func testWrongArgumentTypeIsRejected() {
        let raw = block(#"{"name": "add_diary", "arguments": {"content": "今天很累", "is_private": "是"}}"#)
        XCTAssertThrowsError(try ToolCallProtocol.parse(raw, tools: tools)) { error in
            XCTAssertEqual(
                error as? ToolCallError,
                .invalidArgumentType(tool: "add_diary", argument: "is_private", expected: "布尔", actual: "字符串")
            )
        }
    }

    func testMalformedArgumentsIsRejected() {
        let raw = block(#"{"name": "search_memory", "arguments": "query=考试"}"#)
        XCTAssertThrowsError(try ToolCallProtocol.parse(raw, tools: tools)) { error in
            guard case .malformedEnvelope = (error as? ToolCallError) else {
                return XCTFail("应报 malformedEnvelope，实际 \(error)")
            }
        }
    }

    func testMissingNameIsRejected() {
        let raw = block(#"{"arguments": {}}"#)
        XCTAssertThrowsError(try ToolCallProtocol.parse(raw, tools: tools)) { error in
            guard case .malformedEnvelope = (error as? ToolCallError) else {
                return XCTFail("应报 malformedEnvelope，实际 \(error)")
            }
        }
    }

    func testPromptFragmentIsEmptyWithoutTools() {
        XCTAssertEqual(ToolCallProtocol.promptFragment(tools: []), "")
    }

    func testPromptFragmentListsToolsAndConstraints() {
        let fragment = ToolCallProtocol.promptFragment(tools: tools)
        XCTAssertTrue(fragment.contains("```tool"))
        XCTAssertTrue(fragment.contains("search_memory"))
        XCTAssertTrue(fragment.contains("query: string（必需）"))
        XCTAssertTrue(fragment.contains("limit: number（可选）"))
        XCTAssertTrue(fragment.contains("一次只调用一个工具"))
    }

    func testValidateAllowsDeclaredOptionalArguments() throws {
        let definition = try XCTUnwrap(tools.first)
        XCTAssertNoThrow(
            try ToolCallProtocol.validate(
                arguments: ["query": .string("考试"), "limit": .number(5)],
                against: definition
            )
        )
    }
}
