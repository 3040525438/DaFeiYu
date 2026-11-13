import Foundation
import GRDB
import DFCore

public struct IntegrityReport: Sendable, Equatable {
    public var databaseCheck: String
    public var schemaVersion: String
    public var messageCount: Int
    public var attachmentCount: Int
    public var missingAttachmentFiles: [String]
    public var orphanAttachmentFiles: [String]

    public var isHealthy: Bool {
        databaseCheck.lowercased() == "ok" && missingAttachmentFiles.isEmpty
    }
}

/// 启动自检：库结构、记录数、附件与索引的一致性。
public struct IntegrityChecker: Sendable {
    private let database: AppDatabase
    private let attachments: AttachmentStore

    public init(database: AppDatabase, attachments: AttachmentStore) {
        self.database = database
        self.attachments = attachments
    }

    public func run() throws -> IntegrityReport {
        let check = try database.quickCheck()

        let snapshot: (Int, Int, [String]) = try database.dbQueue.read { db in
            let messageCount = try Message.fetchCount(db)
            let records = try AttachmentRecord.fetchAll(db)
            return (messageCount, records.count, records.map(\.relPath))
        }

        let missing = snapshot.2.filter { !attachments.exists(relativePath: $0) }
        let orphans = (try? attachments.orphanFiles(knownRelativePaths: Set(snapshot.2))) ?? []

        return IntegrityReport(
            databaseCheck: check,
            schemaVersion: database.currentSchemaVersion,
            messageCount: snapshot.0,
            attachmentCount: snapshot.1,
            missingAttachmentFiles: missing,
            orphanAttachmentFiles: orphans
        )
    }
}
