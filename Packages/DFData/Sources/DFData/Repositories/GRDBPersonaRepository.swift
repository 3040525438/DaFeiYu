import Foundation
import GRDB
import DFCore

public struct GRDBPersonaRepository: PersonaRepository, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func corePersona() async throws -> Persona? {
        do {
            return try await database.dbQueue.read { db in
                try Persona
                    .filter(Column("kind") == PersonaKind.core.rawValue)
                    .fetchOne(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func coreSystemPrompt() async throws -> String? {
        do {
            return try await database.dbQueue.read { db in
                guard let persona = try Persona
                    .filter(Column("kind") == PersonaKind.core.rawValue)
                    .fetchOne(db) else {
                    return nil
                }
                return try PersonaItem
                    .filter(Column("persona_id") == persona.id)
                    .filter(Column("section") == "核心")
                    .filter(Column("key") == "system_prompt")
                    .fetchOne(db)?
                    .value
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    public func outerItems() async throws -> [PersonaItem] {
        do {
            return try await database.dbQueue.read { db in
                guard let persona = try Persona
                    .filter(Column("kind") == PersonaKind.outer.rawValue)
                    .fetchOne(db) else {
                    return []
                }
                return try PersonaItem
                    .filter(Column("persona_id") == persona.id)
                    .order(Column("weight").desc)
                    .fetchAll(db)
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }

    /// 只在不存在核心人格时创建一次，重复调用是幂等的。
    public func ensureCorePersona(name: String, systemPrompt: String) async throws -> Persona {
        do {
            return try await database.dbQueue.write { db in
                if let existing = try Persona
                    .filter(Column("kind") == PersonaKind.core.rawValue)
                    .fetchOne(db) {
                    return existing
                }

                let persona = Persona(
                    kind: .core,
                    name: name,
                    isLocked: true,
                    currentVersion: 1
                )
                try persona.insert(db)

                let item = PersonaItem(
                    personaID: persona.id,
                    section: "核心",
                    key: "system_prompt",
                    value: systemPrompt,
                    source: "user"
                )
                try item.insert(db)

                let snapshot = try String(
                    data: JSONEncoder().encode(["name": name, "system_prompt": systemPrompt]),
                    encoding: .utf8
                ) ?? "{}"
                let version = PersonaVersion(
                    personaID: persona.id,
                    version: 1,
                    snapshotJSON: snapshot,
                    changeReason: "初始人格",
                    changedBy: "user"
                )
                try version.insert(db)

                return persona
            }
        } catch {
            throw GRDBErrorMapper.map(error)
        }
    }
}
