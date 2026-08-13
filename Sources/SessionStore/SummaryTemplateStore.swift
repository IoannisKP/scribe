import Foundation
import GRDB

public actor SummaryTemplateStore {
    struct Seed: Equatable, Sendable {
        let key: String
        let name: String
        let body: String
        let sortOrder: Int

        var id: String { "built-in.\(key)" }
    }

    private let database: DatabaseQueue

    public init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, seeds: Self.defaultSeeds)
    }

    init(databaseURL: URL, seeds: [Seed]) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try DatabaseQueue(path: databaseURL.path)
        try Self.migrate(database)
        try Self.seed(seeds, in: database)
    }

    public static func defaultDatabaseURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Scribe/Data", isDirectory: true)
        .appendingPathComponent("templates.sqlite")
    }

    public func templates() throws -> [SummaryTemplate] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, body, builtInKey, sortOrder,
                           createdAt, updatedAt
                    FROM summaryTemplate
                    ORDER BY
                        CASE WHEN builtInKey IS NULL THEN 1 ELSE 0 END,
                        sortOrder,
                        name COLLATE NOCASE,
                        id
                    """
            ).map(Self.template(from:))
        }
    }

    public func create(name: String, body: String) throws -> SummaryTemplate {
        let now = Date()
        let template = try Self.validated(
            SummaryTemplate(
                id: UUID().uuidString,
                name: name,
                body: body,
                sortOrder: 1_000,
                createdAt: now,
                updatedAt: now
            )
        )
        try insert(template)
        return template
    }

    public func save(
        id: String,
        name: String,
        body: String
    ) throws -> SummaryTemplate {
        try database.write { db in
            guard var template = try Self.fetch(id: id, from: db) else {
                throw SummaryTemplateError.templateNotFound
            }
            template.name = name
            template.body = body
            template.updatedAt = Date()
            template = try Self.validated(template)
            try db.execute(
                sql: """
                    UPDATE summaryTemplate
                    SET name = ?, body = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [
                    template.name,
                    template.body,
                    template.updatedAt.timeIntervalSince1970,
                    template.id
                ]
            )
            return template
        }
    }

    public func duplicate(
        id: String,
        name: String
    ) throws -> SummaryTemplate {
        let original = try database.read { db in
            try Self.fetch(id: id, from: db)
        }
        guard let original else { throw SummaryTemplateError.templateNotFound }
        return try create(name: name, body: original.body)
    }

    public func delete(id: String) throws {
        try database.write { db in
            guard let template = try Self.fetch(id: id, from: db) else {
                throw SummaryTemplateError.templateNotFound
            }
            guard !template.isBuiltIn else {
                throw SummaryTemplateError.builtInTemplateCannotBeDeleted
            }
            try db.execute(
                sql: "DELETE FROM summaryTemplate WHERE id = ?",
                arguments: [id]
            )
        }
    }

    private func insert(_ template: SummaryTemplate) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO summaryTemplate(
                        id, name, body, builtInKey, sortOrder,
                        createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    template.id,
                    template.name,
                    template.body,
                    template.builtInKey,
                    template.sortOrder,
                    template.createdAt.timeIntervalSince1970,
                    template.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    private static func validated(
        _ template: SummaryTemplate
    ) throws -> SummaryTemplate {
        var result = template
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty else { throw SummaryTemplateError.missingName }
        guard !result.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SummaryTemplateError.missingBody }
        return result
    }

    private static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("summary-template-v1") { db in
            try db.create(table: "summaryTemplate") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("body", .text).notNull()
                table.column("builtInKey", .text).unique()
                table.column("sortOrder", .integer).notNull()
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
            }
        }
        try migrator.migrate(database)
    }

    private static func seed(
        _ seeds: [Seed],
        in database: DatabaseQueue
    ) throws {
        try database.write { db in
            let now = Date().timeIntervalSince1970
            for seed in seeds {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO summaryTemplate(
                            id, name, body, builtInKey, sortOrder,
                            createdAt, updatedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        seed.id,
                        seed.name,
                        seed.body,
                        seed.key,
                        seed.sortOrder,
                        now,
                        now
                    ]
                )
            }
        }
    }

    private static func fetch(
        id: String,
        from db: Database
    ) throws -> SummaryTemplate? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, name, body, builtInKey, sortOrder,
                       createdAt, updatedAt
                FROM summaryTemplate
                WHERE id = ?
                """,
            arguments: [id]
        ).map(template(from:))
    }

    private static func template(from row: Row) -> SummaryTemplate {
        SummaryTemplate(
            id: row["id"],
            name: row["name"],
            body: row["body"],
            builtInKey: row["builtInKey"],
            sortOrder: row["sortOrder"],
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            updatedAt: Date(timeIntervalSince1970: row["updatedAt"])
        )
    }

    static let defaultSeeds: [Seed] = [
        Seed(
            key: "meeting-summary",
            name: ScribeCopy.SummaryTemplates.meetingSummary,
            body: ScribeCopy.SummaryTemplates.meetingSummaryBody,
            sortOrder: 0
        ),
        Seed(
            key: "decisions-actions",
            name: ScribeCopy.SummaryTemplates.decisionsAndActions,
            body: ScribeCopy.SummaryTemplates.decisionsAndActionsBody,
            sortOrder: 1
        ),
        Seed(
            key: "interview-notes",
            name: ScribeCopy.SummaryTemplates.interviewNotes,
            body: ScribeCopy.SummaryTemplates.interviewNotesBody,
            sortOrder: 2
        ),
        Seed(
            key: "one-to-one",
            name: ScribeCopy.SummaryTemplates.oneToOne,
            body: ScribeCopy.SummaryTemplates.oneToOneBody,
            sortOrder: 3
        ),
        Seed(
            key: "lecture-talk",
            name: ScribeCopy.SummaryTemplates.lectureOrTalk,
            body: ScribeCopy.SummaryTemplates.lectureOrTalkBody,
            sortOrder: 4
        ),
        Seed(
            key: "raw-cleanup",
            name: ScribeCopy.SummaryTemplates.rawCleanup,
            body: ScribeCopy.SummaryTemplates.rawCleanupBody,
            sortOrder: 5
        )
    ]
}
