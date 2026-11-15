import XCTest
@testable import DFCore

/// D04：结构化输出的提取与 Schema 校验。
final class StructuredOutputTests: XCTestCase {
    // MARK: - 提取

    func testExtractsPlainObject() {
        XCTAssertEqual(StructuredOutput.extractObject(from: #"{"a":1}"#), #"{"a":1}"#)
    }

    func testExtractsFromFencedBlockWithProse() {
        let raw = """
        好的，结果如下：
        ```json
        {"name": "小肥", "score": 0.8}
        ```
        以上。
        """
        XCTAssertEqual(
            StructuredOutput.extractObject(from: raw),
            #"{"name": "小肥", "score": 0.8}"#
        )
    }

    func testBracesInsideStringsDoNotBreakExtraction() {
        let raw = #"前缀 {"text": "这里有个 } 花括号"} 后缀"#
        XCTAssertEqual(StructuredOutput.extractObject(from: raw), #"{"text": "这里有个 } 花括号"}"#)
    }

    func testEscapedQuoteInsideString() {
        let raw = #"{"text": "他说：\"好\""}"#
        XCTAssertEqual(StructuredOutput.extractObject(from: raw), raw)
    }

    func testNestedObjectsAreBalanced() {
        let raw = #"{"outer": {"inner": {"x": 1}}}"#
        XCTAssertEqual(StructuredOutput.extractObject(from: raw), raw)
    }

    func testUnclosedObjectReturnsNil() {
        XCTAssertNil(StructuredOutput.extractObject(from: #"{"a": 1"#))
    }

    func testNoBraceReturnsNil() {
        XCTAssertNil(StructuredOutput.extractObject(from: "今天天气不错"))
    }

    // MARK: - 解析

    func testParseEmptyOutputThrows() {
        XCTAssertThrowsError(try StructuredOutput.parse("  ")) { error in
            XCTAssertEqual(error as? StructuredOutputError, .emptyOutput)
        }
    }

    func testParseNonJSONThrows() {
        XCTAssertThrowsError(try StructuredOutput.parse("没有 JSON")) { error in
            XCTAssertEqual(error as? StructuredOutputError, .noJSONObject)
        }
    }

    func testParseInvalidJSONThrows() {
        XCTAssertThrowsError(try StructuredOutput.parse("{a: 1}")) { error in
            guard case .invalidJSON = (error as? StructuredOutputError) else {
                return XCTFail("应报 invalidJSON，实际 \(error)")
            }
        }
    }

    func testParseKeepsTypes() throws {
        let raw = #"{"s": "x", "n": 1.5, "b": true, "z": null, "a": [1,2], "o": {"k": "v"}}"#
        let object = try StructuredOutput.parse(raw)
        XCTAssertEqual(object["s"]?.stringValue, "x")
        XCTAssertEqual(object["n"]?.doubleValue, 1.5)
        XCTAssertEqual(object["b"]?.boolValue, true)
        XCTAssertTrue(object["z"]?.isNull == true)
        XCTAssertEqual(object["a"]?.arrayValue?.count, 2)
        XCTAssertEqual(object["o"]?.objectValue?["k"]?.stringValue, "v")
    }

    func testBoolIsNotNumber() throws {
        let object = try StructuredOutput.parse(#"{"flag": true}"#)
        XCTAssertNil(object["flag"]?.doubleValue)
        XCTAssertEqual(object["flag"]?.boolValue, true)
    }

    // MARK: - Schema

    private var schema: StructuredSchema {
        StructuredSchema(fields: [
            "summary": .init(kind: .string),
            "confidence": .init(kind: .number),
            "evidence": .init(kind: .array),
            "note": .init(kind: .string, required: false)
        ])
    }

    func testSchemaAcceptsValidObject() throws {
        let object = try StructuredOutput.parse(
            #"{"summary": "今天很累", "confidence": 0.7, "evidence": ["今天有点累"]}"#,
            schema: schema
        )
        XCTAssertEqual(object["summary"]?.stringValue, "今天很累")
    }

    func testSchemaRejectsMissingKey() {
        XCTAssertThrowsError(
            try StructuredOutput.parse(#"{"summary": "x", "confidence": 0.5}"#, schema: schema)
        ) { error in
            XCTAssertEqual(error as? StructuredOutputError, .missingKey("evidence"))
        }
    }

    func testSchemaRejectsUnknownKey() {
        XCTAssertThrowsError(
            try StructuredOutput.parse(
                #"{"summary": "x", "confidence": 0.5, "evidence": [], "extra": 1}"#,
                schema: schema
            )
        ) { error in
            XCTAssertEqual(error as? StructuredOutputError, .unexpectedKey("extra"))
        }
    }

    func testSchemaAllowsAdditionalFieldsWhenConfigured() throws {
        var relaxed = schema
        relaxed.allowAdditionalFields = true
        XCTAssertNoThrow(
            try StructuredOutput.parse(
                #"{"summary": "x", "confidence": 0.5, "evidence": [], "extra": 1}"#,
                schema: relaxed
            )
        )
    }

    func testSchemaRejectsTypeMismatch() {
        XCTAssertThrowsError(
            try StructuredOutput.parse(
                #"{"summary": 123, "confidence": 0.5, "evidence": []}"#,
                schema: schema
            )
        ) { error in
            XCTAssertEqual(
                error as? StructuredOutputError,
                .typeMismatch(key: "summary", expected: "字符串", actual: "数字")
            )
        }
    }

    func testOptionalFieldMeansNullOrAbsent() throws {
        XCTAssertNoThrow(
            try StructuredOutput.parse(
                #"{"summary": "x", "confidence": 0.5, "evidence": [], "note": null}"#,
                schema: schema
            )
        )
    }
}
