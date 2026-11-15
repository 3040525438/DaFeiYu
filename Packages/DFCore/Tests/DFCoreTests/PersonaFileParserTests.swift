import XCTest
@testable import DFCore

/// D06：人格文件解析（JSON / Markdown / TXT）
final class PersonaFileParserTests: XCTestCase {
    private func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: - JSON

    func testParseJSONSections() throws {
        let json = """
        {
          "name": "小肥",
          "sections": {
            "性格": { "外向": "是", "耐心": "一般" },
            "喜好": { "饮品": "奶茶" }
          }
        }
        """
        let document = try PersonaFileParser.parse(data: data(json), fileName: "persona.json")

        XCTAssertEqual(document.name, "小肥")
        XCTAssertEqual(document.items.count, 3)
        XCTAssertTrue(document.warnings.isEmpty)
        // section 与 key 都按字典序排序，保证导入顺序稳定
        XCTAssertEqual(document.items.map(\.section), ["喜好", "性格", "性格"])
        XCTAssertEqual(document.items.map(\.key), ["饮品", "外向", "耐心"])
        XCTAssertEqual(document.items.first?.value, "奶茶")
    }

    func testParseJSONItemsArray() throws {
        let json = """
        {
          "items": [
            { "section": "习惯", "key": "作息", "value": "晚睡" },
            { "value": "缺少 section 与 key" },
            { "section": "习惯", "value": "缺少 key" },
            { "section": "习惯", "key": "空值", "value": "   " }
          ]
        }
        """
        let document = try PersonaFileParser.parse(data: data(json), fileName: "persona.json")

        XCTAssertEqual(document.items.count, 3, "空值条目必须被丢弃")
        XCTAssertEqual(document.items[0].section, "习惯")
        XCTAssertEqual(document.items[1].section, "其他")
        XCTAssertEqual(document.items[1].key, "第2条")
        XCTAssertEqual(document.items[2].section, "习惯")
    }

    func testParseJSONTopLevelArray() throws {
        let json = """
        ["喜欢猫", { "section": "偏好", "key": "音乐", "value": "轻音乐" }]
        """
        let document = try PersonaFileParser.parse(data: data(json), fileName: "persona.json")

        XCTAssertNil(document.name)
        XCTAssertEqual(document.items.count, 2)
        XCTAssertEqual(document.items[0].value, "喜欢猫")
        XCTAssertEqual(document.items[0].section, "其他")
        XCTAssertEqual(document.items[1].section, "偏好")
        XCTAssertEqual(document.items[1].key, "音乐")
    }

    func testParseJSONUnknownTopLevelKeysAsSections() throws {
        let json = """
        {
          "version": 2,
          "性格": { "温柔": "是" },
          "兴趣": ["画画", "跑步"]
        }
        """
        let document = try PersonaFileParser.parse(data: data(json), fileName: "persona.json")

        XCTAssertEqual(document.items.count, 3)
        XCTAssertTrue(document.items.contains { $0.section == "性格" && $0.key == "温柔" })
        XCTAssertEqual(document.items.filter { $0.section == "兴趣" }.count, 2)
        XCTAssertFalse(document.items.contains { $0.section == "version" }, "版本号不应被当作人格段落")
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try PersonaFileParser.parse(data: data("{ not json"), fileName: "persona.json")) { error in
            guard case PersonaParseError.malformedJSON = error else {
                return XCTFail("应抛出 malformedJSON，实际：\(error)")
            }
        }
    }

    // MARK: - Markdown

    func testParseMarkdownSectionsAndList() throws {
        let markdown = """
        # 基本信息

        - 名字：大肥鱼
        - 身份: 鲸鱼娘

        ## 偏好

        * 饮品：奶茶
        - 喜欢安静

        ```
        - 代码块里的内容应被忽略
        ```
        """
        let document = try PersonaFileParser.parse(data: data(markdown), fileName: "persona.md")

        XCTAssertNil(document.name)
        XCTAssertEqual(document.items.count, 4, "代码块内容必须跳过")
        XCTAssertEqual(document.items[0].section, "基本信息")
        XCTAssertEqual(document.items[0].key, "名字")
        XCTAssertEqual(document.items[0].value, "大肥鱼")
        XCTAssertEqual(document.items[1].key, "身份")
        XCTAssertEqual(document.items[2].section, "偏好")
        XCTAssertEqual(document.items[2].key, "饮品")
        XCTAssertEqual(document.items[3].key, "第4条·喜欢安静", "无分隔符的行用序号加前缀作为 key")
        XCTAssertEqual(document.items[3].value, "喜欢安静")
    }

    // MARK: - TXT

    func testParseTxtBracketSectionAndSeparators() throws {
        let text = """
        [习惯]
        作息: 晚睡
        口头禅=嘿嘿

        [边界]
        不喜欢被追问行程
        """
        let document = try PersonaFileParser.parse(data: data(text), fileName: "persona.txt")

        XCTAssertEqual(document.items.count, 3)
        XCTAssertEqual(document.items[0].section, "习惯")
        XCTAssertEqual(document.items[0].key, "作息")
        XCTAssertEqual(document.items[1].key, "口头禅")
        XCTAssertEqual(document.items[1].value, "嘿嘿")
        XCTAssertEqual(document.items[2].section, "边界")
        XCTAssertEqual(document.items[2].value, "不喜欢被追问行程")
    }

    func testEmptyDocumentReturnsNoItems() throws {
        let document = try PersonaFileParser.parse(data: data("   \n\n  "), fileName: "persona.md")
        XCTAssertTrue(document.items.isEmpty)
        XCTAssertTrue(document.warnings.isEmpty)
    }

    // MARK: - 去重与截断

    func testDuplicateKeysAreDroppedWithWarning() throws {
        let json = """
        {
          "items": [
            { "section": "性格", "key": "外向", "value": "是" },
            { "section": "性格", "key": "外向", "value": "否" }
          ]
        }
        """
        let document = try PersonaFileParser.parse(data: data(json), fileName: "persona.json")

        XCTAssertEqual(document.items.count, 1)
        XCTAssertEqual(document.items[0].value, "是", "保留首次出现的条目")
        XCTAssertEqual(document.warnings.count, 1)
        XCTAssertTrue(document.warnings[0].contains("重复"))
    }

    func testItemsAreTruncatedToLimit() throws {
        let values = (1...205).map { "\"第\($0)条偏好\"" }.joined(separator: ",")
        let document = try PersonaFileParser.parse(
            data: data("[\(values)]"),
            fileName: "persona.json"
        )

        XCTAssertEqual(document.items.count, PersonaFileParser.maxItems)
        XCTAssertTrue(document.warnings.contains { $0.contains("截断") })
    }

    // MARK: - 格式

    func testUnsupportedFormatThrows() {
        XCTAssertThrowsError(
            try PersonaFileParser.parse(data: data("a: b"), fileName: "persona.yaml")
        ) { error in
            guard case PersonaParseError.unsupportedFormat(let ext) = error else {
                return XCTFail("应抛出 unsupportedFormat，实际：\(error)")
            }
            XCTAssertEqual(ext, "yaml")
        }
    }
}
