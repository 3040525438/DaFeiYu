import Foundation

// MARK: - 结构化输出（D04）
//
// 决策要求"结构化输出实现方式不限定"，因此这里提供一个与模型无关的通用能力：
// 从模型原始文本里**稳妥地**取出 JSON 对象，并按声明式 Schema 校验。
// 不依赖服务端 `response_format`，也不要求模型一定原生支持 JSON 模式。

/// 解析后的 JSON 值。只用于结构化输出与工具参数，不参与持久化。
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// 把 `JSONSerialization` 的结果转成强类型值；不支持的类型返回 nil。
    public static func from(_ any: Any) -> JSONValue? {
        switch any {
        case is NSNull:
            return .null
        case let value as String:
            return .string(value)
        case let value as Bool:
            // Bool 必须在 NSNumber 之前判断，否则 true 会变成 1
            return .boolean(value)
        case let value as NSNumber:
            return .number(value.doubleValue)
        case let value as [Any]:
            var items: [JSONValue] = []
            items.reserveCapacity(value.count)
            for element in value {
                guard let converted = JSONValue.from(element) else { return nil }
                items.append(converted)
            }
            return .array(items)
        case let value as [String: Any]:
            var dict: [String: JSONValue] = [:]
            for (key, element) in value {
                guard let converted = JSONValue.from(element) else { return nil }
                dict[key] = converted
            }
            return .object(dict)
        default:
            return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 描述类型，用于错误提示
    public var typeName: String {
        switch self {
        case .string: return "字符串"
        case .number: return "数字"
        case .boolean: return "布尔"
        case .null: return "null"
        case .array: return "数组"
        case .object: return "对象"
        }
    }
}

public enum StructuredOutputError: Error, Equatable, CustomStringConvertible {
    case emptyOutput
    case noJSONObject
    case invalidJSON(String)
    case missingKey(String)
    case unexpectedKey(String)
    case typeMismatch(key: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .emptyOutput:
            return "模型输出为空"
        case .noJSONObject:
            return "模型输出中没有找到完整的 JSON 对象"
        case .invalidJSON(let reason):
            return "JSON 解析失败：\(reason)"
        case .missingKey(let key):
            return "缺少必需字段：\(key)"
        case .unexpectedKey(let key):
            return "出现未声明的字段：\(key)"
        case .typeMismatch(let key, let expected, let actual):
            return "字段 \(key) 类型应为\(expected)，实际是\(actual)"
        }
    }
}

/// 声明式 Schema：只描述顶层字段与类型，够用且不引入额外依赖。
public struct StructuredSchema: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case string
        case number
        case boolean
        case array
        case object
        /// 不校验类型
        case any

        public var displayName: String {
            switch self {
            case .string: return "字符串"
            case .number: return "数字"
            case .boolean: return "布尔"
            case .array: return "数组"
            case .object: return "对象"
            case .any: return "任意"
            }
        }

        func matches(_ value: JSONValue) -> Bool {
            switch self {
            case .any: return true
            case .string: return value.stringValue != nil
            case .number: return value.doubleValue != nil
            case .boolean: return value.boolValue != nil
            case .array: return value.arrayValue != nil
            case .object: return value.objectValue != nil
            }
        }
    }

    public struct Field: Sendable, Equatable {
        public var kind: Kind
        public var required: Bool

        public init(kind: Kind = .any, required: Bool = true) {
            self.kind = kind
            self.required = required
        }
    }

    public var fields: [String: Field]
    /// 是否允许 Schema 之外的字段
    public var allowAdditionalFields: Bool

    public init(fields: [String: Field], allowAdditionalFields: Bool = false) {
        self.fields = fields
        self.allowAdditionalFields = allowAdditionalFields
    }
}

public enum StructuredOutput {
    /// 从原始输出中提取第一个完整 JSON 对象。
    ///
    /// 容忍：```json 代码块、对象前后的解释文字、字符串里出现的花括号、转义引号。
    /// 未闭合时返回 nil（不猜测残缺结构）。
    public static func extractObject(from raw: String) -> String? {
        let characters = Array(raw)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(characters[start...index])
                    }
                default:
                    break
                }
            }
            index += 1
        }
        return nil
    }

    /// 提取并解析为对象（不做 Schema 校验）。
    public static func parse(_ raw: String) throws -> [String: JSONValue] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StructuredOutputError.emptyOutput }
        guard let candidate = extractObject(from: trimmed) else {
            throw StructuredOutputError.noJSONObject
        }
        guard let data = candidate.data(using: .utf8) else {
            throw StructuredOutputError.invalidJSON("无法按 UTF-8 编码")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw StructuredOutputError.invalidJSON("不是合法 JSON")
        }
        guard let dict = object as? [String: Any], let converted = JSONValue.from(dict)?.objectValue else {
            throw StructuredOutputError.invalidJSON("顶层不是 JSON 对象")
        }
        return converted
    }

    /// 提取、解析并校验。
    public static func parse(_ raw: String, schema: StructuredSchema) throws -> [String: JSONValue] {
        let object = try parse(raw)
        try validate(object, schema: schema)
        return object
    }

    /// 按 Schema 校验字段：必需字段缺失、未声明字段、类型不符都会报错。
    public static func validate(_ object: [String: JSONValue], schema: StructuredSchema) throws {
        if !schema.allowAdditionalFields {
            for key in object.keys where schema.fields[key] == nil {
                throw StructuredOutputError.unexpectedKey(key)
            }
        }
        for (key, field) in schema.fields {
            guard let value = object[key] else {
                if field.required { throw StructuredOutputError.missingKey(key) }
                continue
            }
            // 可选字段显式给 null 视为"没有"，不参与类型校验
            if value.isNull && !field.required { continue }
            guard field.kind.matches(value) else {
                throw StructuredOutputError.typeMismatch(
                    key: key,
                    expected: field.kind.displayName,
                    actual: value.typeName
                )
            }
        }
    }
}
