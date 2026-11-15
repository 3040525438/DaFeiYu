import Foundation

// MARK: - 应用层工具调用兼容（D03）
//
// 决策：不要求模型原生 function calling，由应用层兼容。
// 约定：模型把需要执行的动作写成 ```tool 代码块，内容是
// ```json
// {"name": "工具名", "arguments": {"参数": 值}}
// ```
// 应用层负责：解析 → 工具是否注册 → 参数是否齐全 → 参数类型是否正确。
// 本文件不做任何副作用执行，执行由调用方按 `ToolInvocation` 决定。

public enum ToolArgumentType: String, Sendable, Equatable, CaseIterable {
    case string
    case number
    case boolean

    public var displayName: String {
        switch self {
        case .string: return "字符串"
        case .number: return "数字"
        case .boolean: return "布尔"
        }
    }

    func matches(_ value: JSONValue) -> Bool {
        switch self {
        case .string: return value.stringValue != nil
        case .number: return value.doubleValue != nil
        case .boolean: return value.boolValue != nil
        }
    }
}

/// 一个可被模型调用的工具声明（只描述，不执行）。
public struct ToolDefinition: Sendable, Equatable, Identifiable {
    public var name: String
    /// 一句话说明用途，会写进提示词
    public var summary: String
    public var requiredArguments: [String: ToolArgumentType]
    public var optionalArguments: [String: ToolArgumentType]

    public var id: String { name }

    public init(
        name: String,
        summary: String,
        requiredArguments: [String: ToolArgumentType] = [:],
        optionalArguments: [String: ToolArgumentType] = [:]
    ) {
        self.name = name
        self.summary = summary
        self.requiredArguments = requiredArguments
        self.optionalArguments = optionalArguments
    }

    /// 参数是否已声明（必需或可选）
    func declares(_ argument: String) -> Bool {
        requiredArguments[argument] != nil || optionalArguments[argument] != nil
    }

    func type(of argument: String) -> ToolArgumentType? {
        requiredArguments[argument] ?? optionalArguments[argument]
    }
}

/// 解析并校验通过的一次工具调用。
public struct ToolInvocation: Sendable, Equatable {
    public var name: String
    public var arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }

    /// 常用取参助手
    public func string(_ key: String) -> String? { arguments[key]?.stringValue }
    public func number(_ key: String) -> Double? { arguments[key]?.doubleValue }
    public func bool(_ key: String) -> Bool? { arguments[key]?.boolValue }
}

public enum ToolCallError: Error, Equatable, CustomStringConvertible {
    case emptyOutput
    case noToolCall
    case malformedEnvelope(String)
    case unknownTool(String)
    case missingArgument(tool: String, argument: String)
    case unexpectedArgument(tool: String, argument: String)
    case invalidArgumentType(tool: String, argument: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .emptyOutput:
            return "模型输出为空"
        case .noToolCall:
            return "模型输出里没有工具调用块"
        case .malformedEnvelope(let reason):
            return "工具调用格式不正确：\(reason)"
        case .unknownTool(let name):
            return "调用了未注册的工具：\(name)"
        case .missingArgument(let tool, let argument):
            return "工具 \(tool) 缺少必需参数：\(argument)"
        case .unexpectedArgument(let tool, let argument):
            return "工具 \(tool) 不接受参数：\(argument)"
        case .invalidArgumentType(let tool, let argument, let expected, let actual):
            return "工具 \(tool) 的参数 \(argument) 应为\(expected)，实际是\(actual)"
        }
    }
}

public enum ToolCallProtocol {
    /// 代码块语言标记
    public static let fenceTag = "tool"
    /// 信封里允许表示工具名的键
    public static let nameKeys = ["name", "tool"]
    /// 信封里允许表示参数的键
    public static let argumentsKey = "arguments"

    /// 解析模型输出并做完整校验。
    ///
    /// 只识别第一个 ```tool 代码块；没有代码块时按"没有调用"处理，
    /// 不把普通回复里的 JSON 误判成工具调用。
    public static func parse(_ raw: String, tools: [ToolDefinition]) throws -> ToolInvocation {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolCallError.emptyOutput }
        guard let block = firstToolBlock(in: text) else { throw ToolCallError.noToolCall }

        let object = try StructuredOutput.parse(block)
        guard let name = nameKeys.compactMap({ object[$0]?.stringValue }).first,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolCallError.malformedEnvelope("缺少 name 字段")
        }
        guard let definition = tools.first(where: { $0.name == name }) else {
            throw ToolCallError.unknownTool(name)
        }
        let arguments: [String: JSONValue]
        if let value = object[argumentsKey] {
            guard let dict = value.objectValue else {
                throw ToolCallError.malformedEnvelope("arguments 必须是对象")
            }
            arguments = dict
        } else {
            arguments = [:]
        }

        try validate(arguments: arguments, against: definition)
        return ToolInvocation(name: name, arguments: arguments)
    }

    /// 校验参数：必需齐全、未声明参数拒绝、类型匹配。
    public static func validate(arguments: [String: JSONValue], against definition: ToolDefinition) throws {
        for argument in definition.requiredArguments.keys where arguments[argument] == nil {
            throw ToolCallError.missingArgument(tool: definition.name, argument: argument)
        }
        for (argument, value) in arguments {
            guard definition.declares(argument) else {
                throw ToolCallError.unexpectedArgument(tool: definition.name, argument: argument)
            }
            guard let expected = definition.type(of: argument) else { continue }
            guard expected.matches(value) else {
                throw ToolCallError.invalidArgumentType(
                    tool: definition.name,
                    argument: argument,
                    expected: expected.displayName,
                    actual: value.typeName
                )
            }
        }
    }

    /// 提示词片段：没有注册工具时返回空串，避免把无关协议塞进请求。
    public static func promptFragment(tools: [ToolDefinition]) -> String {
        guard !tools.isEmpty else { return "" }
        var lines: [String] = [
            "【工具调用】",
            "需要调用工具时，只输出一个 ```\(fenceTag) 代码块，内容是 JSON：",
            "{\"name\": \"工具名\", \"arguments\": {参数}}",
            "可用工具："
        ]
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            var signature: [String] = []
            for (key, type) in tool.requiredArguments.sorted(by: { $0.key < $1.key }) {
                signature.append("\(key): \(type.rawValue)（必需）")
            }
            for (key, type) in tool.optionalArguments.sorted(by: { $0.key < $1.key }) {
                signature.append("\(key): \(type.rawValue)（可选）")
            }
            let params = signature.isEmpty ? "无参数" : signature.joined(separator: ", ")
            lines.append("- \(tool.name)(\(params))：\(tool.summary)")
        }
        lines.append("限制：一次只调用一个工具；只能使用上面列出的工具与参数；不得编造参数。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 内部

    private static func firstToolBlock(in text: String) -> String? {
        guard let fenceRange = text.range(of: "```\(fenceTag)") else { return nil }
        let rest = text[fenceRange.upperBound...]
        guard let closing = rest.range(of: "```") else { return nil }
        let body = rest[..<closing.lowerBound]
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
