import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Server-Sent Events 解析器。
/// 只实现本项目的需要：按行喂入，空行触发一次事件，支持多行 data 拼接。
public struct SSEParser {
    private var dataLines: [String] = []
    private var eventName: String?

    public init() {}

    /// 喂入一行（不含换行符）。返回完整事件表示当前事件在此结束。
    public mutating func consume(line rawLine: String) -> SSEEvent? {
        var line = rawLine
        if line.hasSuffix("\r") {
            line.removeLast()
        }

        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            return nil
        }

        guard let separator = line.firstIndex(of: ":") else {
            if line == "data" {
                dataLines.append("")
            }
            return nil
        }

        let field = String(line[line.startIndex..<separator])
        var value = String(line[line.index(after: separator)...])
        if value.hasPrefix(" ") {
            value.removeFirst()
        }

        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            eventName = value
        default:
            break
        }
        return nil
    }

    public mutating func flush() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            eventName = nil
            return nil
        }
        let event = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        dataLines.removeAll(keepingCapacity: true)
        eventName = nil
        return event
    }

    /// 测试与离线解析用：把整段文本拆成事件列表
    public static func parse(_ text: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = parser.consume(line: String(line)) {
                events.append(event)
            }
        }
        if let event = parser.flush() {
            events.append(event)
        }
        return events
    }
}
