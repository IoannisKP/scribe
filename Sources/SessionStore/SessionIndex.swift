import Foundation
import GRDB

public struct IndexedSession: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let directory: URL
    public let source: String
    public let isAvailable: Bool

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        directory: URL,
        source: String,
        isAvailable: Bool
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.directory = directory
        self.source = source
        self.isAvailable = isAvailable
    }
}

public struct IndexedArtifact: Equatable, Sendable {
    public let relativePath: String
    public let kind: String
    public let byteCount: Int64
    public let modifiedAt: Date?

    public init(
        relativePath: String,
        kind: String,
        byteCount: Int64,
        modifiedAt: Date?
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct SessionSmartFolderCounts: Equatable, Sendable {
    public let allSessions: Int
    public let needsSummary: Int
    public let imported: Int

    public static let zero = SessionSmartFolderCounts(
        allSessions: 0,
        needsSummary: 0,
        imported: 0
    )

    public init(
        allSessions: Int,
        needsSummary: Int,
        imported: Int
    ) {
        self.allSessions = allSessions
        self.needsSummary = needsSummary
        self.imported = imported
    }
}

public actor SessionIndex {
    private let database: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try DatabaseQueue(path: databaseURL.path)
        try Self.migrate(database)
    }

    public func replace(
        session: IndexedSession,
        artifacts: [IndexedArtifact],
        transcript: String,
        notes: String,
        summary: String
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO session(
                        id, title, createdAt, path, source, available
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        createdAt = excluded.createdAt,
                        path = excluded.path,
                        source = excluded.source,
                        available = excluded.available
                    """,
                arguments: [
                    session.id.uuidString,
                    session.title,
                    session.createdAt.timeIntervalSince1970,
                    session.directory.path,
                    session.source,
                    session.isAvailable
                ]
            )
            try db.execute(
                sql: "DELETE FROM artifact WHERE sessionID = ?",
                arguments: [session.id.uuidString]
            )
            for artifact in artifacts {
                try db.execute(
                    sql: """
                        INSERT INTO artifact(
                            sessionID, relativePath, kind, byteCount, modifiedAt
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        session.id.uuidString,
                        artifact.relativePath,
                        artifact.kind,
                        artifact.byteCount,
                        artifact.modifiedAt?.timeIntervalSince1970
                    ]
                )
            }
            try db.execute(
                sql: "DELETE FROM sessionText WHERE sessionID = ?",
                arguments: [session.id.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO sessionText(
                        sessionID, title, transcript, notes, summary
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    session.id.uuidString,
                    session.title,
                    transcript,
                    notes,
                    summary
                ]
            )
        }
    }

    public func removeSessions(notIn ids: Set<UUID>) throws {
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM session")
            for row in rows {
                let string: String = row["id"]
                guard let id = UUID(uuidString: string), !ids.contains(id) else {
                    continue
                }
                try db.execute(
                    sql: "DELETE FROM session WHERE id = ?",
                    arguments: [string]
                )
                try db.execute(
                    sql: "DELETE FROM sessionText WHERE sessionID = ?",
                    arguments: [string]
                )
            }
        }
    }

    public func markAllUnavailable() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE session SET available = 0")
        }
    }

    public func sessions() throws -> [IndexedSession] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, createdAt, path, source, available
                    FROM session
                    ORDER BY createdAt DESC, title COLLATE NOCASE
                    """
            ).compactMap(Self.session(from:))
        }
    }

    public func smartFolderCounts() throws -> SessionSmartFolderCounts {
        try database.read { db in
            let allSessions = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM session"
            ) ?? 0
            let needsSummary = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM session s
                    WHERE NOT EXISTS (
                        SELECT 1 FROM artifact a
                        WHERE a.sessionID = s.id AND a.kind = 'summary'
                    )
                    """
            ) ?? 0
            let imported = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM session
                    WHERE source = 'importedFile'
                    """
            ) ?? 0
            return SessionSmartFolderCounts(
                allSessions: allSessions,
                needsSummary: needsSummary,
                imported: imported
            )
        }
    }

    public func search(_ query: String) throws -> [IndexedSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try sessions() }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id, s.title, s.createdAt, s.path, s.source,
                           s.available
                    FROM sessionText
                    JOIN session s ON s.id = sessionText.sessionID
                    WHERE sessionText MATCH ?
                    ORDER BY bm25(sessionText), s.createdAt DESC
                    """,
                arguments: [trimmed]
            ).compactMap(Self.session(from:))
        }
    }

    public func deleteDatabaseFiles() throws {
        let path = database.path
        try database.close()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("session-index-v1") { db in
            try db.create(table: "session") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("createdAt", .double).notNull()
                table.column("path", .text).notNull()
                table.column("source", .text).notNull()
                table.column("available", .boolean).notNull()
            }
            try db.create(table: "artifact") { table in
                table.column("sessionID", .text)
                    .notNull()
                    .references("session", onDelete: .cascade)
                table.column("relativePath", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("byteCount", .integer).notNull()
                table.column("modifiedAt", .double)
                table.primaryKey(["sessionID", "relativePath"])
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE sessionText USING fts5(
                    sessionID UNINDEXED,
                    title,
                    transcript,
                    notes,
                    summary,
                    tokenize = 'unicode61'
                )
                """)
        }
        try migrator.migrate(database)
    }

    private static func session(from row: Row) -> IndexedSession? {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else { return nil }
        let timestamp: Double = row["createdAt"]
        let path: String = row["path"]
        return IndexedSession(
            id: id,
            title: row["title"],
            createdAt: Date(timeIntervalSince1970: timestamp),
            directory: URL(fileURLWithPath: path, isDirectory: true),
            source: row["source"],
            isAvailable: row["available"]
        )
    }
}
