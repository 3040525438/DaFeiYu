import Foundation

/// 规范迁移序列（唯一顺序来源）。
///
/// 规则（R6 冻结口径）：
/// 1. 只能在**末尾追加**，禁止重排、改名、删除；
/// 2. 数据库里的 `grdb_migrations` 只用来表示"哪些已执行"，**不用 rowid、不用时间列**排序；
/// 3. 已应用集合必须恰好等于本清单的前 N 项，否则视为顺序错误，迁移必须中止。
public enum MigrationID: String, CaseIterable, Sendable {
    case v1_phase1
    case v2_memory
    case v3_chat
    case v4_persona
    case v5_autonomy
    case v6_character
    case v7_meta_backup
    case v8_chat_v2
    case v9_astrbot
    case v10_multimodal
    case v11_local_models
}

public enum MigrationOrderError: Error, Equatable, CustomStringConvertible {
    /// 台账里出现了规范清单之外的 identifier
    case unknownIdentifier(String)
    /// 已应用集合不是规范清单的前缀（缺号、乱序、跳阶段）
    case notPrefix(expected: [String], actual: [String])
    /// 某个迁移执行时，本次 identifier 不在预期前缀的末位
    case unexpectedCurrent(String, expected: String)

    public var description: String {
        switch self {
        case .unknownIdentifier(let value):
            return "迁移台账出现未知 identifier：\(value)"
        case .notPrefix(let expected, let actual):
            return "迁移顺序与规范清单不一致：期望 \(expected)，实际 \(actual)"
        case .unexpectedCurrent(let current, let expected):
            return "本次迁移应为 \(expected)，实际注册的是 \(current)"
        }
    }
}

/// 迁移台账的规范顺序与摘要工具（不依赖数据库 rowid / 时间列）。
public enum MigrationLedger {
    /// 规范顺序（append-only）
    public static var canonicalIdentifiers: [String] {
        MigrationID.allCases.map(\.rawValue)
    }

    /// 取规范清单前 count 项
    public static func expectedPrefix(count: Int) -> [String] {
        Array(canonicalIdentifiers.prefix(max(0, count)))
    }

    /// 校验"已应用集合"必须恰好是规范清单的前 N 项，并返回规范顺序的数组。
    public static func validatedPrefix(applied: [String]) throws -> [String] {
        let unknown = applied.filter { !canonicalIdentifiers.contains($0) }
        guard unknown.isEmpty else {
            throw MigrationOrderError.unknownIdentifier(unknown.joined(separator: ","))
        }
        let expected = expectedPrefix(count: applied.count)
        guard Set(applied) == Set(expected), applied.count == Set(applied).count else {
            throw MigrationOrderError.notPrefix(expected: expected, actual: applied)
        }
        return expected
    }

    /// ledger_digest：SHA-256("migrations-v1\n" + 前 N 项以 LF 连接)
    /// 排除 rowid、时间、设备信息，保证跨设备可复现。
    public static func digest(prefix: [String]) -> String {
        SHA256.hash("migrations-v1\n" + prefix.joined(separator: "\n"))
    }
}
