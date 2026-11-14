import Foundation

/// 人格指纹（P-05 / P-11）。
///
/// 规则（设计文档 02 章 5.3）：
/// - 只取 `core`（核心层）与 `outer`（外围层）的条目，`pending` 不参与；
/// - 归一化：空白折叠、key 转小写、忽略 id / 时间戳 / weight；
/// - 稳定排序后整体做 SHA-256，保证跨设备、跨模型可复现；
/// - 不一致时只报告"人格漂移"，不自动修复。
public enum PersonaFingerprint {
    /// 指纹覆盖范围
    public enum Scope: String, CaseIterable, Sendable {
        /// 只含核心层：换模型前后必须一致
        case core
        /// 核心层 + 外围层：身份 + 成长轨迹的整体指纹
        case coreOuter = "core_outer"

        /// 该范围纳入的 tier 集合
        var tiers: Set<String> {
            switch self {
            case .core: return ["core"]
            case .coreOuter: return ["core", "outer"]
            }
        }
    }

    /// 参与指纹计算的最小条目（不依赖数据库行模型）
    public struct Item: Hashable, Sendable {
        public var key: String
        public var value: String
        public var tier: String

        public init(key: String, value: String, tier: String) {
            self.key = key
            self.value = value
            self.tier = tier
        }
    }

    /// 算法标识，写入 `persona_fingerprints.algorithm`
    public static let algorithm = "sha256-v1"

    /// 空白折叠：连续空白（含换行）压成一个半角空格并去首尾
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 计算指纹与该范围内的条目数
    public static func compute(items: [Item], scope: Scope) -> (fingerprint: String, itemCount: Int) {
        let tiers = scope.tiers
        let lines = items
            .filter { tiers.contains($0.tier) }
            .map { item in
                item.tier + "\u{1F}" + normalize(item.key).lowercased() + "\u{1F}" + normalize(item.value)
            }
            .sorted()
        return (SHA256.hash("persona-fingerprint-v1\n" + lines.joined(separator: "\n")), lines.count)
    }
}
