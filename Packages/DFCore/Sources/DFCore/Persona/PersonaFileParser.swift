import Foundation

/// 人格文件解析（D06）：支持 JSON / Markdown / TXT，不写库、不做网络请求。
///
/// 产物只描述"文件里有什么"，写入必须走 `PersonaGrowthService` 的提案与审批，
/// 避免导入直接改核心人格或绕过确认。
public struct ParsedPersonaItem: Sendable, Equatable {
    public var section: String
    public var key: String
    public var value: String

    public init(section: String, key: String, value: String) {
        self.section = section
        self.key = key
        self.value = value
    }
}

public struct ParsedPersonaDocument: Sendable, Equatable {
    public var name: String?
    public var items: [ParsedPersonaItem]
    /// 解析过程中的提示（重复条目、超量截断等），不影响导入
    public var warnings: [String]

    public init(name: String?, items: [ParsedPersonaItem], warnings: [String]) {
        self.name = name
        self.items = items
        self.warnings = warnings
    }
}

public enum PersonaParseError: Error, Equatable, CustomStringConvertible {
    case unsupportedFormat(String)
    case emptyDocument
    case malformedJSON(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let ext):
            return "不支持的人格文件格式：\(ext.isEmpty ? "未知" : ext)"
        case .emptyDocument:
            return "人格文件里没有可导入的条目"
        case .malformedJSON(let reason):
            return "人格 JSON 解析失败：\(reason)"
        }
    }
}

public enum PersonaFileParser {
    /// 单文件最多导入的条目数，超出截断并写 warning
    public static let maxItems = 200

    public static func parse(data: Data, fileName: String) throws -> ParsedPersonaDocument {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "json" {
            return try parseJSON(data)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersonaParseError.unsupportedFormat(ext)
        }
        if ext == "md" || ext == "markdown" {
            return try parseText(text, markdown: true)
        }
        if ext == "txt" || ext.isEmpty {
            return try parseText(text, markdown: false)
        }
        throw PersonaParseError.unsupportedFormat(ext)
    }

    // MARK: - JSON

    private static func parseJSON(_ data: Data) throws -> ParsedPersonaDocument {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PersonaParseError.malformedJSON(error.localizedDescription)
        }

        var name: String?
        var items: [ParsedPersonaItem] = []

        if let array = object as? [Any] {
            items = parseItemArray(array)
        } else if let dict = object as? [String: Any] {
            name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawItems = dict["items"] as? [Any] {
                items = parseItemArray(rawItems)
            } else if let sections = dict["sections"] as? [String: Any] {
                items = parseSections(sections)
            } else {
                var sections: [String: Any] = [:]
                for (key, value) in dict where !["name", "version", "description", "items", "sections"].contains(key) {
                    sections[key] = value
                }
                items = parseSections(sections)
            }
        }

        return finalize(name: name, items: items)
    }

    private static func parseItemArray(_ array: [Any]) -> [ParsedPersonaItem] {
        var result: [ParsedPersonaItem] = []
        for element in array {
            if let dict = element as? [String: Any],
               let value = stringValue(dict["value"]),
               !value.isEmpty {
                let section = stringValue(dict["section"]) ?? "其他"
                let key = stringValue(dict["key"]) ?? "第\(result.count + 1)条"
                result.append(ParsedPersonaItem(section: section, key: key, value: value))
            } else if let text = element as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(ParsedPersonaItem(
                    section: "其他",
                    key: "第\(result.count + 1)条",
                    value: text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
        return result
    }

    private static func parseSections(_ sections: [String: Any]) -> [ParsedPersonaItem] {
        var result: [ParsedPersonaItem] = []
        for section in sections.keys.sorted() {
            let sectionName = section.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionName.isEmpty else { continue }
            guard let value = sections[section] else { continue }

            if let dict = value as? [String: Any] {
                for key in dict.keys.sorted() {
                    if let text = stringValue(dict[key]), !text.isEmpty {
                        result.append(ParsedPersonaItem(section: sectionName, key: key, value: text))
                    }
                }
            } else if let array = value as? [Any] {
                for element in array {
                    if let text = stringValue(element), !text.isEmpty {
                        result.append(ParsedPersonaItem(
                            section: sectionName,
                            key: "第\(result.count + 1)条",
                            value: text
                        ))
                    } else if let dict = element as? [String: Any],
                              let text = stringValue(dict["value"]),
                              !text.isEmpty {
                        let key = stringValue(dict["key"]) ?? "第\(result.count + 1)条"
                        result.append(ParsedPersonaItem(section: sectionName, key: key, value: text))
                    }
                }
            } else if let text = stringValue(value), !text.isEmpty {
                result.append(ParsedPersonaItem(section: sectionName, key: "描述", value: text))
            }
        }
        return result
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let text = any as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = any as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    // MARK: - Markdown / TXT

    private static func parseText(_ text: String, markdown: Bool) throws -> ParsedPersonaDocument {
        var currentSection = "其他"
        var items: [ParsedPersonaItem] = []
        var counter = 0
        var inFence = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 代码块内的内容不是人格设定，整段跳过
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            // 标题：[小标题] / # 标题 / ## 标题
            if line.hasPrefix("#") {
                currentSection = normalizeSection(String(line.drop(while: { $0 == "#" })))
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = normalizeSection(String(line.dropFirst().dropLast()))
                continue
            }

            var content = line
            if markdown {
                for prefix in ["- ", "* ", "+ "] where content.hasPrefix(prefix) {
                    content = String(content.dropFirst(prefix.count))
                    break
                }
            }

            guard !content.isEmpty else { continue }
            counter += 1

            let (key, value) = splitKeyValue(content, index: counter)
            items.append(ParsedPersonaItem(section: currentSection, key: key, value: value))
        }

        return finalize(name: nil, items: items)
    }

    private static func normalizeSection(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "其他" : trimmed
    }

    /// 支持 `key：value` / `key: value` / `key=value`；否则整行作为内容，key 用序号
    private static func splitKeyValue(_ text: String, index: Int) -> (String, String) {
        for separator in ["：", ":", "="] {
            if let range = text.range(of: separator) {
                let key = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !value.isEmpty {
                    return (key, value)
                }
            }
        }
        let clipped = String(text.prefix(20))
        return ("第\(index)条·\(clipped)", text)
    }

    // MARK: - 汇总

    private static func finalize(name: String?, items: [ParsedPersonaItem]) -> ParsedPersonaDocument {
        var cleaned: [ParsedPersonaItem] = []
        var seen = Set<String>()
        var warnings: [String] = []
        var duplicated = 0
        var truncated = false

        for item in items {
            // 达到上限且后面还有内容，才算截断（刚好 maxItems 条时不应报警）
            if cleaned.count >= maxItems {
                truncated = true
                break
            }
            let section = item.section.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let identity = "\(section)|\(key)"
            if seen.contains(identity) {
                duplicated += 1
                continue
            }
            seen.insert(identity)
            cleaned.append(ParsedPersonaItem(
                section: section.isEmpty ? "其他" : section,
                key: key.isEmpty ? "第\(cleaned.count + 1)条" : key,
                value: value
            ))
        }

        if truncated {
            warnings.append("条目超过 \(maxItems) 条，已截断")
        }
        if duplicated > 0 {
            warnings.append("忽略了 \(duplicated) 条重复的同名条目")
        }
        guard !cleaned.isEmpty else {
            return ParsedPersonaDocument(name: name, items: [], warnings: warnings)
        }
        return ParsedPersonaDocument(name: name, items: cleaned, warnings: warnings)
    }
}
