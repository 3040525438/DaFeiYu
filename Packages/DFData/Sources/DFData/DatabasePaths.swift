import Foundation

/// 一个环境（正式版 / 实验版）对应的全部本地路径。
/// 两个环境使用完全不同的根目录，互不可见。
public struct DatabasePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var databaseURL: URL {
        root.appendingPathComponent("dafeiyu.sqlite", isDirectory: false)
    }

    public var attachmentsRoot: URL {
        root.appendingPathComponent("Attachments", isDirectory: true)
    }

    public var workspace: URL {
        root.appendingPathComponent("Workspace", isDirectory: true)
    }

    public var logs: URL {
        root.appendingPathComponent("Logs", isDirectory: true)
    }
}
