import Foundation

/// AstrBot 迁移的 `begin_dialogs`（开场对话示例）格式化。
///
/// 硬规则：
/// - 只做**排版**（role → 说话人标签），不改写任何对话内容；
/// - JSON 解析失败时原样输出原始文本，不丢弃、不摘要；
/// - 空内容返回 nil，调用方据此跳过该段。
public enum BeginDialogsFormatter {
    /// 把 AstrBot 的 begin_dialogs JSON 数组排版成提示词可读的对话行。
    ///
    /// 输入形如：`[{"role":"user","content":"你好"},{"role":"ai","content":"来啦？"}]`
    /// 输出形如：
    /// ```
    /// 用户：你好
    /// 你：来啦？
    /// ```
    /// - Parameters:
    ///   - raw: persona_items 里存的原始 JSON 文本。
    ///   - selfLabel: AI 侧说话人标签（默认"你"）。
    public static func format(_ raw: String, selfLabel: String = "你") -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            // 不是合法 JSON：原样保留，不截断、不改写
            return trimmed
        }

        var lines: [String] = []
        for element in array {
            guard let dict = element as? [String: Any],
                  let content = dict["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let role = (dict["role"] as? String ?? "").lowercased()
            // AstrBot 里用户侧一般是 user，其余（ai/assistant/bot）都视为 AI 自己
            let speaker = (role == "user") ? "用户" : selfLabel
            lines.append("\(speaker)：\(content.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        guard !lines.isEmpty else {
            // JSON 合法但没有任何可用对话（例如空数组）：回退原始文本
            return lines.isEmpty && array.isEmpty ? nil : trimmed
        }
        return lines.joined(separator: "\n")
    }
}
