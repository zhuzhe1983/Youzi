import CryptoKit
import Foundation
import SQLite3

private enum YouziSQLiteValue {
    case null
    case text(String)
    case integer(Int64)
    case real(Double)
}

private final class YouziSQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            throw YouziMemoryRepositoryError.databaseUnavailable
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String, _ bindings: [YouziSQLiteValue] = []) throws {
        guard let handle else { throw YouziMemoryRepositoryError.databaseUnavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw YouziMemoryRepositoryError.databaseUnavailable }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: continue
            case SQLITE_DONE: return
            case SQLITE_CONSTRAINT: throw YouziMemoryRepositoryError.integrityViolation
            default: throw YouziMemoryRepositoryError.databaseUnavailable
            }
        }
    }

    func rows(
        _ sql: String,
        _ bindings: [YouziSQLiteValue] = []
    ) throws -> [[String: String]] {
        guard let handle else { throw YouziMemoryRepositoryError.databaseUnavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw YouziMemoryRepositoryError.databaseUnavailable }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else {
                throw YouziMemoryRepositoryError.databaseUnavailable
            }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index) else { continue }
                let key = String(cString: name)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[key] = String(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[key] = String(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    if let pointer = sqlite3_column_text(statement, index) {
                        row[key] = String(cString: pointer)
                    }
                default:
                    break
                }
            }
            result.append(row)
        }
    }

    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func bind(_ values: [YouziSQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case let .text(value):
                code = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, Self.transient)
                }
            case let .integer(value):
                code = sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                code = sqlite3_bind_double(statement, index, value)
            }
            guard code == SQLITE_OK else {
                throw YouziMemoryRepositoryError.databaseUnavailable
            }
        }
    }
}

private enum YouziMemorySchema {
    static let currentVersion = 2

    static let versionOne = [
        """
        CREATE TABLE IF NOT EXISTS memory_metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS migration_ledger (
          migration_key TEXT PRIMARY KEY NOT NULL,
          applied_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS operation_dedup (
          operation_key TEXT PRIMARY KEY NOT NULL,
          operation_kind TEXT NOT NULL,
          result_json TEXT NOT NULL,
          created_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_source (
          id TEXT PRIMARY KEY NOT NULL,
          kind TEXT NOT NULL,
          external_identifier TEXT NOT NULL,
          revision TEXT NOT NULL,
          title TEXT NOT NULL,
          scope_kind TEXT NOT NULL,
          scope_id TEXT,
          task_id TEXT,
          workspace_id TEXT,
          project_id TEXT,
          permission_id TEXT,
          import_mode TEXT,
          authorization TEXT NOT NULL,
          content_checksum TEXT,
          imported_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          deleted_at REAL,
          UNIQUE(kind, external_identifier, revision)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_citation (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES memory_source(id),
          source_revision TEXT NOT NULL,
          locator_json TEXT NOT NULL,
          source_timestamp REAL,
          excerpt TEXT NOT NULL,
          content_checksum TEXT NOT NULL,
          created_at REAL NOT NULL,
          UNIQUE(source_id, source_revision, locator_json)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_node (
          id TEXT PRIMARY KEY NOT NULL,
          canonical_key TEXT NOT NULL,
          label TEXT NOT NULL,
          content TEXT NOT NULL,
          kind TEXT NOT NULL,
          confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
          sensitivity TEXT NOT NULL,
          scope_kind TEXT NOT NULL,
          scope_id TEXT,
          state TEXT NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0),
          valid_from REAL,
          valid_until REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          last_confirmed_at REAL,
          deleted_at REAL,
          merged_into_id TEXT REFERENCES memory_node(id)
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS memory_node_active_key
          ON memory_node(scope_kind, IFNULL(scope_id, ''), canonical_key)
          WHERE deleted_at IS NULL AND state NOT IN ('forgotten', 'superseded')
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_edge (
          id TEXT PRIMARY KEY NOT NULL,
          source_node_id TEXT NOT NULL REFERENCES memory_node(id),
          target_node_id TEXT NOT NULL REFERENCES memory_node(id),
          relation TEXT NOT NULL,
          explanation TEXT NOT NULL,
          confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
          sensitivity TEXT NOT NULL,
          scope_kind TEXT NOT NULL,
          scope_id TEXT,
          state TEXT NOT NULL,
          revision INTEGER NOT NULL CHECK(revision > 0),
          valid_from REAL,
          valid_until REAL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          deleted_at REAL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_node_citation (
          node_id TEXT NOT NULL REFERENCES memory_node(id) ON DELETE CASCADE,
          citation_id TEXT NOT NULL REFERENCES memory_citation(id),
          PRIMARY KEY(node_id, citation_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_edge_citation (
          edge_id TEXT NOT NULL REFERENCES memory_edge(id) ON DELETE CASCADE,
          citation_id TEXT NOT NULL REFERENCES memory_citation(id),
          PRIMARY KEY(edge_id, citation_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_ingestion_job (
          id TEXT PRIMARY KEY NOT NULL,
          source_id TEXT NOT NULL REFERENCES memory_source(id),
          source_revision TEXT NOT NULL,
          extractor_version TEXT NOT NULL,
          policy_version TEXT NOT NULL,
          priority INTEGER NOT NULL,
          state TEXT NOT NULL,
          attempt_count INTEGER NOT NULL,
          next_attempt_at REAL,
          lease_owner TEXT,
          lease_expires_at REAL,
          recovery_code TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(source_id, source_revision, extractor_version, policy_version)
        )
        """,
        "CREATE INDEX IF NOT EXISTS memory_ingestion_ready ON memory_ingestion_job(state, next_attempt_at, priority, created_at)"
    ]

    static let versionTwo = [
        """
        CREATE TABLE IF NOT EXISTS memory_category (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL,
          is_system INTEGER NOT NULL,
          is_hidden INTEGER NOT NULL,
          sort_order INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS memory_category_name ON memory_category(name COLLATE NOCASE)",
        """
        CREATE TABLE IF NOT EXISTS memory_category_membership (
          category_id TEXT NOT NULL REFERENCES memory_category(id) ON DELETE CASCADE,
          node_id TEXT NOT NULL REFERENCES memory_node(id) ON DELETE CASCADE,
          PRIMARY KEY(category_id, node_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_source_category (
          source_id TEXT NOT NULL REFERENCES memory_source(id) ON DELETE CASCADE,
          category_id TEXT NOT NULL REFERENCES memory_category(id) ON DELETE CASCADE,
          PRIMARY KEY(source_id, category_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_ingestion_segment (
          job_id TEXT NOT NULL REFERENCES memory_ingestion_job(id) ON DELETE CASCADE,
          segment_id TEXT NOT NULL,
          checksum TEXT NOT NULL,
          ordinal INTEGER NOT NULL,
          PRIMARY KEY(job_id, segment_id),
          UNIQUE(job_id, ordinal)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_merge (
          id TEXT PRIMARY KEY NOT NULL,
          primary_node_id TEXT NOT NULL REFERENCES memory_node(id),
          duplicate_node_id TEXT NOT NULL REFERENCES memory_node(id),
          primary_revision_before INTEGER NOT NULL,
          duplicate_revision_before INTEGER NOT NULL,
          duplicate_state_before TEXT NOT NULL,
          created_at REAL NOT NULL,
          undone_at REAL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS memory_audit (
          id TEXT PRIMARY KEY NOT NULL,
          action TEXT NOT NULL,
          target_id TEXT NOT NULL,
          related_id TEXT,
          before_revision INTEGER,
          after_revision INTEGER,
          request_id TEXT,
          occurred_at REAL NOT NULL
        )
        """,
        // Trigram supports the product's Chinese substring search without an
        // external tokenizer while remaining an FTS5 index.
        "CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(node_id UNINDEXED, label, content, tokenize='trigram')"
    ]
}

// MARK: - SQLite authority

actor YouziMemoryRepository: YouziMemoryIngestionQueue, YouziMemoryIdleIngestionService {
    static let currentSchemaVersion = YouziMemorySchema.currentVersion
    static let maximumLabelCharacters = 200
    static let maximumContentCharacters = 4_096
    static let maximumExcerptCharacters = 1_024
    static let maximumQueryCharacters = 512
    static let maximumFileBytes: Int64 = 512 * 1_024 * 1_024

    private let database: YouziSQLiteConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let uuid: @Sendable () -> UUID

    init(databaseURL: URL, uuid: @escaping @Sendable () -> UUID = UUID.init) throws {
        guard databaseURL.isFileURL, databaseURL.path.hasPrefix("/") else {
            throw YouziMemoryRepositoryError.databaseUnavailable
        }
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw YouziMemoryRepositoryError.databaseUnavailable
        }
        database = try YouziSQLiteConnection(url: databaseURL)
        self.uuid = uuid
        try Self.prepare(database: database)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
    }

#if DEBUG
    static func createVersionOneFixture(at databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = try YouziSQLiteConnection(url: databaseURL)
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.transaction {
            for statement in YouziMemorySchema.versionOne { try connection.execute(statement) }
            try connection.execute("PRAGMA user_version = 1")
        }
    }

    static func createUnsupportedSchemaFixture(at databaseURL: URL, version: Int) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = try YouziSQLiteConnection(url: databaseURL)
        try connection.execute("PRAGMA user_version = \(version)")
    }
#endif

    func schemaVersion() throws -> Int {
        try Self.userVersion(database)
    }

    func integrityCheck() throws {
        guard try database.rows("PRAGMA integrity_check").first?["integrity_check"] == "ok",
              try database.rows("PRAGMA foreign_key_check").isEmpty
        else { throw YouziMemoryRepositoryError.integrityViolation }
    }

    private static func prepare(database: YouziSQLiteConnection) throws {
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = FULL")
        let version = try userVersion(database)
        guard version <= YouziMemorySchema.currentVersion else {
            throw YouziMemoryRepositoryError.unsupportedSchemaVersion(version)
        }
        do {
            if version < 1 {
                try database.transaction {
                    for statement in YouziMemorySchema.versionOne { try database.execute(statement) }
                    try database.execute("PRAGMA user_version = 1")
                }
            }
            if version < 2 {
                do {
                    try database.transaction {
                        for statement in YouziMemorySchema.versionTwo { try database.execute(statement) }
                        try database.execute("PRAGMA user_version = 2")
                    }
                } catch {
                    throw YouziMemoryRepositoryError.fullTextSearchUnavailable
                }
            }
            guard try userVersion(database) == YouziMemorySchema.currentVersion,
                  try database.rows("PRAGMA integrity_check").first?["integrity_check"] == "ok",
                  try database.rows("PRAGMA foreign_key_check").isEmpty
            else { throw YouziMemoryRepositoryError.integrityViolation }
        } catch let error as YouziMemoryRepositoryError {
            throw error
        } catch {
            throw YouziMemoryRepositoryError.migrationFailed
        }
    }

    private static func userVersion(_ database: YouziSQLiteConnection) throws -> Int {
        guard let value = try database.rows("PRAGMA user_version").first?["user_version"],
              let version = Int(value)
        else { throw YouziMemoryRepositoryError.databaseUnavailable }
        return version
    }
}

// MARK: - Sources, evidence, and categories

extension YouziMemoryRepository {
    @discardableResult
    func registerSource(_ source: YouziMemorySourceRecord) throws -> YouziMemorySourceRecord {
        var normalized = source
        normalized.externalIdentifier = Self.redact(source.externalIdentifier)
        normalized.title = Self.redact(source.title)
        try validate(normalized)
        return try database.transaction {
            if let existing = try self.source(id: normalized.id) {
                guard existing == normalized else { throw YouziMemoryRepositoryError.revisionConflict }
                return existing
            }
            if let existing = try self.source(
                kind: normalized.kind,
                externalIdentifier: normalized.externalIdentifier,
                revision: normalized.revision
            ) {
                guard existing.contentChecksum == normalized.contentChecksum,
                      existing.scope == normalized.scope,
                      existing.permissionID == normalized.permissionID,
                      existing.importMode == normalized.importMode
                else { throw YouziMemoryRepositoryError.revisionConflict }
                return existing
            }
            try insertSource(normalized)
            return normalized
        }
    }

    func source(id: UUID) throws -> YouziMemorySourceRecord? {
        try database.rows(
            "SELECT * FROM memory_source WHERE id = ?",
            [.text(id.youziSQLite)]
        ).first.map(decodeSource)
    }

    @discardableResult
    func addCitation(_ citation: YouziMemoryCitationRecord) throws -> YouziMemoryCitationRecord {
        var normalized = citation
        normalized.excerpt = Self.redact(citation.excerpt)
        try validate(normalized)
        return try database.transaction {
            guard let source = try source(id: normalized.sourceID) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard source.authorization == .authorized else {
                throw YouziMemoryRepositoryError.sourceUnauthorized
            }
            guard source.revision == normalized.sourceRevision else {
                throw YouziMemoryRepositoryError.sourceRevisionChanged
            }
            if let existing = try self.citation(id: normalized.id) {
                guard existing == normalized else { throw YouziMemoryRepositoryError.revisionConflict }
                return existing
            }
            let locator = try encodeJSON(normalized.locator)
            try database.execute(
                """
                INSERT INTO memory_citation
                  (id, source_id, source_revision, locator_json, source_timestamp,
                   excerpt, content_checksum, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(normalized.id.youziSQLite), .text(normalized.sourceID.youziSQLite),
                    .text(normalized.sourceRevision), .text(locator),
                    normalized.sourceTimestamp.map(\.youziSQLite) ?? .null,
                    .text(normalized.excerpt), .text(normalized.contentChecksum),
                    normalized.createdAt.youziSQLite
                ]
            )
            return try self.citation(id: normalized.id) ?? normalized
        }
    }

    func citation(id: UUID) throws -> YouziMemoryCitationRecord? {
        try database.rows(
            "SELECT * FROM memory_citation WHERE id = ?",
            [.text(id.youziSQLite)]
        ).first.map(decodeCitation)
    }

    func citations(nodeID: UUID, context: YouziMemoryAccessContext) throws -> [YouziMemoryCitationRecord] {
        try validate(context)
        let rows = try database.rows(
            """
            SELECT c.*, s.authorization, s.scope_kind, s.scope_id
            FROM memory_citation c
            JOIN memory_node_citation nc ON nc.citation_id = c.id
            JOIN memory_source s ON s.id = c.source_id
            WHERE nc.node_id = ?
            ORDER BY c.created_at DESC
            """,
            [.text(nodeID.youziSQLite)]
        )
        return try rows.compactMap { row in
            guard try contextAllows(row: row, context: context) else { return nil }
            var result = try decodeCitation(row)
            if row["authorization"] != YouziMemorySourceAuthorization.authorized.rawValue {
                result.excerpt = ""
            }
            return result
        }
    }

    @discardableResult
    func upsertCategory(_ category: YouziMemoryCategoryRecord) throws -> YouziMemoryCategoryRecord {
        try requireText(category.name, maximum: 100)
        try database.execute(
            """
            INSERT INTO memory_category
              (id, name, is_system, is_hidden, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              is_hidden = excluded.is_hidden,
              sort_order = excluded.sort_order,
              updated_at = excluded.updated_at
            """,
            [
                .text(category.id.youziSQLite), .text(Self.redact(category.name)),
                .integer(category.isSystem ? 1 : 0), .integer(category.isHidden ? 1 : 0),
                .integer(Int64(category.sortOrder)), category.createdAt.youziSQLite,
                category.updatedAt.youziSQLite
            ]
        )
        return category
    }

    func categories() throws -> [YouziMemoryCategoryRecord] {
        try database.rows(
            "SELECT * FROM memory_category ORDER BY sort_order, name COLLATE NOCASE"
        ).map(decodeCategory)
    }

    @discardableResult
    func seedSystemCategories(at: Date) throws -> [YouziMemoryCategoryRecord] {
        let names = [
            "关于我", "人物与关系", "偏好与习惯", "目标与计划", "经历与事件",
            "项目与工作", "知识主题", "重要日期", "待确认"
        ]
        return try database.transaction {
            var result: [YouziMemoryCategoryRecord] = []
            for (index, name) in names.enumerated() {
                let id = Self.stableUUID("youzi-system-memory-category:\(name)")
                if let row = try database.rows(
                    "SELECT * FROM memory_category WHERE id = ?", [.text(id.youziSQLite)]
                ).first {
                    result.append(try decodeCategory(row))
                    continue
                }
                let category = YouziMemoryCategoryRecord(
                    id: id, name: name, isSystem: true, isHidden: false,
                    sortOrder: index, createdAt: at, updatedAt: at
                )
                try database.execute(
                    """
                    INSERT INTO memory_category
                      (id, name, is_system, is_hidden, sort_order, created_at, updated_at)
                    VALUES (?, ?, 1, 0, ?, ?, ?)
                    """,
                    [
                        .text(id.youziSQLite), .text(name), .integer(Int64(index)),
                        at.youziSQLite, at.youziSQLite
                    ]
                )
                result.append(category)
            }
            return result
        }
    }

    @discardableResult
    func classifySource(
        id: UUID,
        scope: YouziMemoryScopeRecord,
        categoryIDs: [UUID],
        at: Date
    ) throws -> YouziMemorySourceRecord {
        guard scope.isValid, categoryIDs.count <= 20,
              Set(categoryIDs).count == categoryIDs.count
        else { throw YouziMemoryRepositoryError.invalidInput(.invalidScope) }
        return try database.transaction {
            guard var existing = try source(id: id) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard existing.authorization == .authorized else {
                throw YouziMemoryRepositoryError.sourceUnauthorized
            }
            try requireCategories(categoryIDs)
            try database.execute(
                "UPDATE memory_source SET scope_kind = ?, scope_id = ?, updated_at = ? WHERE id = ?",
                [
                    .text(scope.kind.rawValue),
                    scope.identifier.map { .text($0.youziSQLite) } ?? .null,
                    at.youziSQLite, .text(id.youziSQLite)
                ]
            )
            try replaceSourceCategories(sourceID: id, categoryIDs: categoryIDs)
            existing.scope = scope
            existing.updatedAt = at
            return existing
        }
    }

    func sourceCategoryIDs(sourceID: UUID) throws -> [UUID] {
        try database.rows(
            "SELECT category_id FROM memory_source_category WHERE source_id = ? ORDER BY category_id",
            [.text(sourceID.youziSQLite)]
        ).compactMap { $0["category_id"].flatMap(UUID.init(uuidString:)) }
    }

    @discardableResult
    func revokeSource(id: UUID, at: Date) throws -> YouziMemorySourceRecord {
        try database.transaction {
            guard var existing = try source(id: id) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            if existing.authorization == .revoked { return existing }
            let affected = try database.rows(
                """
                SELECT DISTINCT nc.node_id
                FROM memory_node_citation nc
                JOIN memory_citation c ON c.id = nc.citation_id
                WHERE c.source_id = ?
                """,
                [.text(id.youziSQLite)]
            ).compactMap { $0["node_id"] }
            try database.execute(
                "UPDATE memory_source SET authorization = ?, updated_at = ? WHERE id = ?",
                [.text(YouziMemorySourceAuthorization.revoked.rawValue), at.youziSQLite, .text(id.youziSQLite)]
            )
            // Evidence text is unavailable immediately after revocation. The
            // checksum and locator remain as plaintext-free provenance.
            try database.execute(
                "UPDATE memory_citation SET excerpt = '' WHERE source_id = ?",
                [.text(id.youziSQLite)]
            )
            for nodeID in affected { try reindexNode(id: nodeID) }
            existing.authorization = .revoked
            existing.updatedAt = at
            return existing
        }
    }

    private func insertSource(_ source: YouziMemorySourceRecord) throws {
        try database.execute(
            """
            INSERT INTO memory_source
              (id, kind, external_identifier, revision, title, scope_kind, scope_id,
               task_id, workspace_id, project_id, permission_id, import_mode,
               authorization, content_checksum, imported_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(source.id.youziSQLite), .text(source.kind.rawValue),
                .text(Self.redact(source.externalIdentifier)), .text(source.revision),
                .text(Self.redact(source.title)), .text(source.scope.kind.rawValue),
                source.scope.identifier.map { .text($0.youziSQLite) } ?? .null,
                source.taskID.map { .text($0.youziSQLite) } ?? .null,
                source.workspaceID.map { .text($0.youziSQLite) } ?? .null,
                source.projectID.map { .text($0.youziSQLite) } ?? .null,
                source.permissionID.map { .text($0.youziSQLite) } ?? .null,
                source.importMode.map { .text($0.rawValue) } ?? .null,
                .text(source.authorization.rawValue),
                source.contentChecksum.map(YouziSQLiteValue.text) ?? .null,
                source.importedAt.youziSQLite, source.updatedAt.youziSQLite,
                source.deletedAt.map(\.youziSQLite) ?? .null
            ]
        )
    }

    private func source(
        kind: YouziMemorySourceKind,
        externalIdentifier: String,
        revision: String
    ) throws -> YouziMemorySourceRecord? {
        try database.rows(
            "SELECT * FROM memory_source WHERE kind = ? AND external_identifier = ? AND revision = ?",
            [.text(kind.rawValue), .text(Self.redact(externalIdentifier)), .text(revision)]
        ).first.map(decodeSource)
    }
}

// MARK: - Internal invariants and row mapping

private extension YouziMemoryRepository {
    func validate(_ source: YouziMemorySourceRecord) throws {
        try requireText(source.externalIdentifier, maximum: 500)
        try requireText(source.revision, maximum: 200)
        try requireText(source.title, maximum: 300)
        guard source.scope.isValid else { throw YouziMemoryRepositoryError.invalidInput(.invalidScope) }
        if source.scope.kind == .project,
           let projectID = source.projectID,
           source.scope.identifier != projectID {
            throw YouziMemoryRepositoryError.invalidInput(.invalidScope)
        }
        if source.scope.kind == .workspace,
           let workspaceID = source.workspaceID,
           source.scope.identifier != workspaceID {
            throw YouziMemoryRepositoryError.invalidInput(.invalidScope)
        }
        if let checksum = source.contentChecksum, !Self.validChecksum(checksum) {
            throw YouziMemoryRepositoryError.invalidInput(.invalidChecksum)
        }
        if source.kind == .manualFile, source.permissionID == nil || source.importMode == nil {
            throw YouziMemoryRepositoryError.sourceUnauthorized
        }
    }

    func validate(_ citation: YouziMemoryCitationRecord) throws {
        try requireText(citation.sourceRevision, maximum: 200)
        try requireText(citation.locator.key, maximum: 800)
        if let detail = citation.locator.detail { try requireText(detail, maximum: 500) }
        guard citation.excerpt.count <= Self.maximumExcerptCharacters else {
            throw YouziMemoryRepositoryError.invalidInput(.valueTooLong)
        }
        guard Self.validChecksum(citation.contentChecksum) else {
            throw YouziMemoryRepositoryError.invalidInput(.invalidChecksum)
        }
    }

    func validate(_ context: YouziMemoryAccessContext) throws {
        guard (1...20).contains(context.maximumResults),
              !context.allowedScopes.isEmpty,
              context.allowedScopes.allSatisfy(\.isValid)
        else { throw YouziMemoryRepositoryError.invalidInput(.invalidLimit) }
    }

    func validate(_ batch: YouziMemoryCandidateBatch) throws {
        try requireSafeIdentifier(batch.idempotencyKey, maximum: 200)
        try requireSafeIdentifier(batch.policyVersion, maximum: 100)
        try requireText(batch.sourceRevision, maximum: 200)
        guard batch.nodes.count <= 100, batch.edges.count <= 200 else {
            throw YouziMemoryRepositoryError.invalidInput(.invalidLimit)
        }
        let nodeIDs = batch.nodes.map(\.id)
        let edgeIDs = batch.edges.map(\.id)
        guard Set(nodeIDs).count == nodeIDs.count, Set(edgeIDs).count == edgeIDs.count else {
            throw YouziMemoryRepositoryError.duplicateRecord
        }
        for candidate in batch.nodes {
            try requireText(candidate.canonicalKey, maximum: 300)
            try requireText(candidate.label, maximum: Self.maximumLabelCharacters)
            try requireText(candidate.content, maximum: Self.maximumContentCharacters)
            guard (0...1).contains(candidate.confidence), candidate.scope.isValid,
                  candidate.citationIDs.count <= 50,
                  candidate.categoryIDs.count <= 20,
                  Set(candidate.citationIDs).count == candidate.citationIDs.count,
                  Set(candidate.categoryIDs).count == candidate.categoryIDs.count
            else { throw YouziMemoryRepositoryError.invalidInput(.invalidConfidence) }
        }
        for candidate in batch.edges {
            try requireText(candidate.explanation, maximum: 1_000)
            guard candidate.sourceNodeID != candidate.targetNodeID,
                  (0...1).contains(candidate.confidence), candidate.scope.isValid,
                  candidate.citationIDs.count <= 50,
                  Set(candidate.citationIDs).count == candidate.citationIDs.count
            else { throw YouziMemoryRepositoryError.invalidInput(.invalidConfidence) }
        }
    }

    func validate(_ request: YouziMemoryFileImportRequest) throws {
        try requireText(request.displayName, maximum: 300)
        try requireSafeIdentifier(request.uniformTypeIdentifier, maximum: 200)
        try requireSafeIdentifier(request.extractorVersion, maximum: 100)
        try requireSafeIdentifier(request.policyVersion, maximum: 100)
        guard request.scope.isValid,
              request.byteCount >= 0,
              request.byteCount <= Self.maximumFileBytes,
              Self.validChecksum(request.sha256),
              request.categoryIDs.count <= 20,
              Set(request.categoryIDs).count == request.categoryIDs.count
        else { throw YouziMemoryRepositoryError.invalidInput(.invalidChecksum) }
        let allowed = [
            "public.pdf", "public.plain-text", "public.utf8-plain-text",
            "net.daringfireball.markdown", "org.openxmlformats.wordprocessingml.document",
            "org.openxmlformats.spreadsheetml.sheet",
            "org.openxmlformats.presentationml.presentation", "com.apple.webarchive",
            "public.png", "public.jpeg", "public.heic", "public.tiff"
        ]
        guard allowed.contains(request.uniformTypeIdentifier.lowercased()) else {
            throw YouziMemoryRepositoryError.invalidInput(.unsupportedFile)
        }
    }

    func requireText(_ value: String, maximum: Int) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw YouziMemoryRepositoryError.invalidInput(.emptyValue) }
        guard value.count <= maximum else { throw YouziMemoryRepositoryError.invalidInput(.valueTooLong) }
    }

    func requireSafeIdentifier(_ value: String, maximum: Int) throws {
        try requireText(value, maximum: maximum)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw YouziMemoryRepositoryError.invalidInput(.emptyValue)
        }
    }

    func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        guard let string = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw YouziMemoryRepositoryError.integrityViolation
        }
        return string
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        guard let data = value.data(using: .utf8) else {
            throw YouziMemoryRepositoryError.integrityViolation
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw YouziMemoryRepositoryError.integrityViolation }
    }

    func decodeSource(_ row: [String: String]) throws -> YouziMemorySourceRecord {
        guard let id = uuid(row, "id"),
              let kind = enumValue(YouziMemorySourceKind.self, row, "kind"),
              let external = row["external_identifier"],
              let revision = row["revision"],
              let title = row["title"],
              let scope = scope(row),
              let authorization = enumValue(YouziMemorySourceAuthorization.self, row, "authorization"),
              let importedAt = date(row, "imported_at"),
              let updatedAt = date(row, "updated_at")
        else { throw YouziMemoryRepositoryError.integrityViolation }
        return .init(
            id: id, kind: kind, externalIdentifier: external, revision: revision,
            title: title, scope: scope,
            taskID: uuid(row, "task_id"), workspaceID: uuid(row, "workspace_id"),
            projectID: uuid(row, "project_id"), permissionID: uuid(row, "permission_id"),
            importMode: enumValue(YouziMemoryImportMode.self, row, "import_mode"),
            authorization: authorization, contentChecksum: row["content_checksum"],
            importedAt: importedAt, updatedAt: updatedAt, deletedAt: date(row, "deleted_at")
        )
    }

    func decodeCitation(_ row: [String: String]) throws -> YouziMemoryCitationRecord {
        guard let id = uuid(row, "id"), let sourceID = uuid(row, "source_id"),
              let sourceRevision = row["source_revision"],
              let locatorJSON = row["locator_json"], let excerpt = row["excerpt"],
              let checksum = row["content_checksum"], let createdAt = date(row, "created_at")
        else { throw YouziMemoryRepositoryError.integrityViolation }
        return .init(
            id: id, sourceID: sourceID, sourceRevision: sourceRevision,
            locator: try decodeJSON(YouziMemorySourceLocator.self, from: locatorJSON),
            sourceTimestamp: date(row, "source_timestamp"), excerpt: excerpt,
            contentChecksum: checksum, createdAt: createdAt
        )
    }

    func decodeNode(_ row: [String: String]) throws -> YouziMemoryNodeRecord {
        guard let id = uuid(row, "id"), let canonical = row["canonical_key"],
              let label = row["label"], let content = row["content"],
              let kind = enumValue(YouziMemoryRecordKind.self, row, "kind"),
              let confidence = double(row, "confidence"),
              let sensitivity = enumValue(YouziMemorySensitivity.self, row, "sensitivity"),
              let scope = scope(row),
              let state = enumValue(YouziMemoryRecordState.self, row, "state"),
              let revision = int(row, "revision"), let createdAt = date(row, "created_at"),
              let updatedAt = date(row, "updated_at")
        else { throw YouziMemoryRepositoryError.integrityViolation }
        return .init(
            id: id, canonicalKey: canonical, label: label, content: content,
            kind: kind, confidence: confidence, sensitivity: sensitivity,
            scope: scope, state: state, revision: revision,
            validFrom: date(row, "valid_from"), validUntil: date(row, "valid_until"),
            createdAt: createdAt, updatedAt: updatedAt,
            lastConfirmedAt: date(row, "last_confirmed_at"),
            deletedAt: date(row, "deleted_at"), mergedIntoID: uuid(row, "merged_into_id")
        )
    }

    func decodeEdge(_ row: [String: String]) throws -> YouziMemoryEdgeRecord {
        guard let id = uuid(row, "id"), let sourceID = uuid(row, "source_node_id"),
              let targetID = uuid(row, "target_node_id"),
              let relation = enumValue(YouziMemoryRelationKind.self, row, "relation"),
              let explanation = row["explanation"],
              let confidence = double(row, "confidence"),
              let sensitivity = enumValue(YouziMemorySensitivity.self, row, "sensitivity"),
              let scope = scope(row),
              let state = enumValue(YouziMemoryRecordState.self, row, "state"),
              let revision = int(row, "revision"), let createdAt = date(row, "created_at"),
              let updatedAt = date(row, "updated_at")
        else { throw YouziMemoryRepositoryError.integrityViolation }
        return .init(
            id: id, sourceNodeID: sourceID, targetNodeID: targetID,
            relation: relation, explanation: explanation, confidence: confidence,
            sensitivity: sensitivity, scope: scope, state: state, revision: revision,
            validFrom: date(row, "valid_from"), validUntil: date(row, "valid_until"),
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: date(row, "deleted_at")
        )
    }

    func decodeCategory(_ row: [String: String]) throws -> YouziMemoryCategoryRecord {
        guard let id = uuid(row, "id"), let name = row["name"],
              let system = int(row, "is_system"), let hidden = int(row, "is_hidden"),
              let order = int(row, "sort_order"), let created = date(row, "created_at"),
              let updated = date(row, "updated_at")
        else { throw YouziMemoryRepositoryError.integrityViolation }
        return .init(
            id: id, name: name, isSystem: system != 0, isHidden: hidden != 0,
            sortOrder: order, createdAt: created, updatedAt: updated
        )
    }

    func decodeJob(_ row: [String: String]) throws -> YouziMemoryIngestionJob {
        guard let id = uuid(row, "id"), let sourceID = uuid(row, "source_id"),
              let sourceRevision = row["source_revision"],
              let extractor = row["extractor_version"], let policy = row["policy_version"],
              let priority = int(row, "priority"),
              let state = enumValue(YouziMemoryIngestionJobState.self, row, "state"),
              let attempts = int(row, "attempt_count"),
              let created = date(row, "created_at"), let updated = date(row, "updated_at")
        else { throw YouziMemoryRepositoryError.integrityViolation }
        return .init(
            id: id, sourceID: sourceID, sourceRevision: sourceRevision,
            extractorVersion: extractor, policyVersion: policy, priority: priority,
            state: state, attemptCount: attempts, nextAttemptAt: date(row, "next_attempt_at"),
            leaseOwner: row["lease_owner"], leaseExpiresAt: date(row, "lease_expires_at"),
            recoveryCode: row["recovery_code"], createdAt: created, updatedAt: updated
        )
    }

    func uuid(_ row: [String: String], _ key: String) -> UUID? {
        row[key].flatMap(UUID.init(uuidString:))
    }

    func date(_ row: [String: String], _ key: String) -> Date? {
        row[key].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    func int(_ row: [String: String], _ key: String) -> Int? { row[key].flatMap(Int.init) }
    func double(_ row: [String: String], _ key: String) -> Double? { row[key].flatMap(Double.init) }

    func enumValue<T: RawRepresentable>(
        _ type: T.Type, _ row: [String: String], _ key: String
    ) -> T? where T.RawValue == String {
        row[key].flatMap(T.init(rawValue:))
    }

    func scope(_ row: [String: String]) -> YouziMemoryScopeRecord? {
        guard let kind = enumValue(YouziMemoryScopeKind.self, row, "scope_kind") else { return nil }
        let scope = YouziMemoryScopeRecord(kind: kind, identifier: uuid(row, "scope_id"))
        return scope.isValid ? scope : nil
    }

    func contextAllows(
        scope: YouziMemoryScopeRecord,
        sensitivity: YouziMemorySensitivity,
        context: YouziMemoryAccessContext
    ) throws -> Bool {
        guard context.allowedScopes.contains(scope) else { return false }
        return sensitivity != .sensitive && sensitivity != .sealed || context.mayReadSensitive
    }

    func contextAllows(row: [String: String], context: YouziMemoryAccessContext) throws -> Bool {
        guard let scope = scope(row) else { throw YouziMemoryRepositoryError.integrityViolation }
        return context.allowedScopes.contains(scope)
    }

    func operationResult(key: String) throws -> YouziMemoryProposalResult? {
        guard let json = try database.rows(
            "SELECT result_json FROM operation_dedup WHERE operation_key = ? AND operation_kind = 'propose'",
            [.text(key)]
        ).first?["result_json"] else { return nil }
        return try decodeJSON(YouziMemoryProposalResult.self, from: json)
    }

    func activeNodeID(canonicalKey: String, scope: YouziMemoryScopeRecord) throws -> UUID? {
        let rows = try database.rows(
            """
            SELECT id FROM memory_node
            WHERE scope_kind = ? AND IFNULL(scope_id, '') = IFNULL(?, '')
              AND canonical_key = ? AND deleted_at IS NULL
              AND state NOT IN ('forgotten', 'superseded')
            LIMIT 1
            """,
            [
                .text(scope.kind.rawValue),
                scope.identifier.map { .text($0.youziSQLite) } ?? .null,
                .text(Self.canonicalKey(canonicalKey))
            ]
        )
        return rows.first?["id"].flatMap(UUID.init(uuidString:))
    }

    func upsertCandidate(
        _ candidate: YouziMemoryNodeCandidate,
        sourceID: UUID,
        at: Date
    ) throws -> UUID {
        let canonical = Self.canonicalKey(candidate.canonicalKey)
        if let collision = try node(id: candidate.id), collision.canonicalKey != canonical {
            throw YouziMemoryRepositoryError.duplicateRecord
        }
        if let existingID = try activeNodeID(canonicalKey: canonical, scope: candidate.scope),
           var existing = try node(id: existingID) {
            let revision = existing.revision + 1
            try database.execute(
                "UPDATE memory_node SET confidence = ?, revision = ?, updated_at = ? WHERE id = ?",
                [
                    .real(max(existing.confidence, candidate.confidence)), .integer(Int64(revision)),
                    at.youziSQLite, .text(existingID.youziSQLite)
                ]
            )
            existing.confidence = max(existing.confidence, candidate.confidence)
            for citationID in candidate.citationIDs {
                try requireCitation(citationID, sourceID: sourceID)
                try attachCitation(citationID, toNode: existingID)
            }
            for categoryID in candidate.categoryIDs { try attachCategory(categoryID, toNode: existingID) }
            try reindexNode(id: existingID)
            return existingID
        }
        let state: YouziMemoryRecordState = candidate.sensitivity == .ordinary && candidate.confidence >= 0.7
            ? .proposed : .awaitingConfirmation
        let record = YouziMemoryNodeRecord(
            id: candidate.id, canonicalKey: canonical,
            label: Self.redact(candidate.label), content: Self.redact(candidate.content),
            kind: candidate.kind, confidence: candidate.confidence,
            sensitivity: candidate.sensitivity, scope: candidate.scope, state: state,
            revision: 1, validFrom: candidate.validFrom, validUntil: candidate.validUntil,
            createdAt: at, updatedAt: at, lastConfirmedAt: nil,
            deletedAt: nil, mergedIntoID: nil
        )
        try insertNode(record)
        for citationID in candidate.citationIDs {
            try requireCitation(citationID, sourceID: sourceID)
            try attachCitation(citationID, toNode: candidate.id)
        }
        for categoryID in candidate.categoryIDs { try attachCategory(categoryID, toNode: candidate.id) }
        try reindexNode(id: candidate.id)
        return candidate.id
    }

    func insertCandidateEdge(
        _ candidate: YouziMemoryEdgeCandidate,
        sourceID: UUID,
        at: Date
    ) throws {
        guard try node(id: candidate.sourceNodeID) != nil,
              try node(id: candidate.targetNodeID) != nil
        else { throw YouziMemoryRepositoryError.integrityViolation }
        guard try edge(id: candidate.id) == nil else {
            throw YouziMemoryRepositoryError.duplicateRecord
        }
        let state: YouziMemoryRecordState = candidate.sensitivity == .ordinary && candidate.confidence >= 0.7
            ? .proposed : .awaitingConfirmation
        let record = YouziMemoryEdgeRecord(
            id: candidate.id, sourceNodeID: candidate.sourceNodeID,
            targetNodeID: candidate.targetNodeID, relation: candidate.relation,
            explanation: Self.redact(candidate.explanation), confidence: candidate.confidence,
            sensitivity: candidate.sensitivity, scope: candidate.scope, state: state,
            revision: 1, validFrom: candidate.validFrom, validUntil: candidate.validUntil,
            createdAt: at, updatedAt: at, deletedAt: nil
        )
        try insertEdge(record)
        for citationID in candidate.citationIDs {
            try requireCitation(citationID, sourceID: sourceID)
            try attachCitation(citationID, toEdge: candidate.id)
        }
    }

    func insertNode(_ node: YouziMemoryNodeRecord) throws {
        try database.execute(
            """
            INSERT INTO memory_node
              (id, canonical_key, label, content, kind, confidence, sensitivity,
               scope_kind, scope_id, state, revision, valid_from, valid_until,
               created_at, updated_at, last_confirmed_at, deleted_at, merged_into_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(node.id.youziSQLite), .text(node.canonicalKey), .text(node.label),
                .text(node.content), .text(node.kind.rawValue), .real(node.confidence),
                .text(node.sensitivity.rawValue), .text(node.scope.kind.rawValue),
                node.scope.identifier.map { .text($0.youziSQLite) } ?? .null,
                .text(node.state.rawValue), .integer(Int64(node.revision)),
                node.validFrom.map(\.youziSQLite) ?? .null,
                node.validUntil.map(\.youziSQLite) ?? .null,
                node.createdAt.youziSQLite, node.updatedAt.youziSQLite,
                node.lastConfirmedAt.map(\.youziSQLite) ?? .null,
                node.deletedAt.map(\.youziSQLite) ?? .null,
                node.mergedIntoID.map { .text($0.youziSQLite) } ?? .null
            ]
        )
    }

    func insertEdge(_ edge: YouziMemoryEdgeRecord) throws {
        try database.execute(
            """
            INSERT INTO memory_edge
              (id, source_node_id, target_node_id, relation, explanation,
               confidence, sensitivity, scope_kind, scope_id, state, revision,
               valid_from, valid_until, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(edge.id.youziSQLite), .text(edge.sourceNodeID.youziSQLite),
                .text(edge.targetNodeID.youziSQLite), .text(edge.relation.rawValue),
                .text(edge.explanation), .real(edge.confidence), .text(edge.sensitivity.rawValue),
                .text(edge.scope.kind.rawValue),
                edge.scope.identifier.map { .text($0.youziSQLite) } ?? .null,
                .text(edge.state.rawValue), .integer(Int64(edge.revision)),
                edge.validFrom.map(\.youziSQLite) ?? .null,
                edge.validUntil.map(\.youziSQLite) ?? .null,
                edge.createdAt.youziSQLite, edge.updatedAt.youziSQLite,
                edge.deletedAt.map(\.youziSQLite) ?? .null
            ]
        )
    }

    func insertCitation(_ citation: YouziMemoryCitationRecord) throws {
        try database.execute(
            """
            INSERT INTO memory_citation
              (id, source_id, source_revision, locator_json, source_timestamp,
               excerpt, content_checksum, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(citation.id.youziSQLite), .text(citation.sourceID.youziSQLite),
                .text(citation.sourceRevision), .text(try encodeJSON(citation.locator)),
                citation.sourceTimestamp.map(\.youziSQLite) ?? .null,
                .text(citation.excerpt), .text(citation.contentChecksum),
                citation.createdAt.youziSQLite
            ]
        )
    }

    func edge(id: UUID) throws -> YouziMemoryEdgeRecord? {
        try database.rows("SELECT * FROM memory_edge WHERE id = ?", [.text(id.youziSQLite)])
            .first.map(decodeEdge)
    }

    func attachCitation(_ citationID: UUID, toNode nodeID: UUID) throws {
        try database.execute(
            "INSERT OR IGNORE INTO memory_node_citation(node_id, citation_id) VALUES (?, ?)",
            [.text(nodeID.youziSQLite), .text(citationID.youziSQLite)]
        )
    }

    func attachCitation(_ citationID: UUID, toEdge edgeID: UUID) throws {
        try database.execute(
            "INSERT OR IGNORE INTO memory_edge_citation(edge_id, citation_id) VALUES (?, ?)",
            [.text(edgeID.youziSQLite), .text(citationID.youziSQLite)]
        )
    }

    func attachCategory(_ categoryID: UUID, toNode nodeID: UUID) throws {
        guard try !database.rows(
            "SELECT id FROM memory_category WHERE id = ?", [.text(categoryID.youziSQLite)]
        ).isEmpty else { throw YouziMemoryRepositoryError.recordNotFound }
        try database.execute(
            "INSERT OR IGNORE INTO memory_category_membership(category_id, node_id) VALUES (?, ?)",
            [.text(categoryID.youziSQLite), .text(nodeID.youziSQLite)]
        )
    }

    func requireCategories(_ categoryIDs: [UUID]) throws {
        for categoryID in categoryIDs {
            guard try !database.rows(
                "SELECT id FROM memory_category WHERE id = ?", [.text(categoryID.youziSQLite)]
            ).isEmpty else { throw YouziMemoryRepositoryError.recordNotFound }
        }
    }

    func replaceSourceCategories(sourceID: UUID, categoryIDs: [UUID]) throws {
        try database.execute(
            "DELETE FROM memory_source_category WHERE source_id = ?",
            [.text(sourceID.youziSQLite)]
        )
        for categoryID in categoryIDs {
            try database.execute(
                "INSERT INTO memory_source_category(source_id, category_id) VALUES (?, ?)",
                [.text(sourceID.youziSQLite), .text(categoryID.youziSQLite)]
            )
        }
    }

    func requireCitation(_ citationID: UUID, sourceID: UUID) throws {
        guard let row = try database.rows(
            "SELECT source_id FROM memory_citation WHERE id = ?",
            [.text(citationID.youziSQLite)]
        ).first else { throw YouziMemoryRepositoryError.recordNotFound }
        guard row["source_id"] == sourceID.youziSQLite else {
            throw YouziMemoryRepositoryError.sourceUnauthorized
        }
    }

    func citationIDs(nodeID: UUID) throws -> [UUID] {
        try database.rows(
            "SELECT citation_id FROM memory_node_citation WHERE node_id = ? ORDER BY citation_id",
            [.text(nodeID.youziSQLite)]
        ).compactMap { $0["citation_id"].flatMap(UUID.init(uuidString:)) }
    }

    func hasAuthorizedCitationOrManual(nodeID: UUID) throws -> Bool {
        let total = try database.rows(
            "SELECT COUNT(*) AS count FROM memory_node_citation WHERE node_id = ?",
            [.text(nodeID.youziSQLite)]
        ).first?["count"].flatMap(Int.init) ?? 0
        if total == 0 { return true }
        let authorized = try database.rows(
            """
            SELECT COUNT(*) AS count FROM memory_node_citation nc
            JOIN memory_citation c ON c.id = nc.citation_id
            JOIN memory_source s ON s.id = c.source_id
            WHERE nc.node_id = ? AND s.authorization = 'authorized'
              AND s.revision = c.source_revision
            """,
            [.text(nodeID.youziSQLite)]
        ).first?["count"].flatMap(Int.init) ?? 0
        return authorized > 0
    }

    func hasAuthorizedCitationOrManual(edgeID: UUID) throws -> Bool {
        let total = try database.rows(
            "SELECT COUNT(*) AS count FROM memory_edge_citation WHERE edge_id = ?",
            [.text(edgeID.youziSQLite)]
        ).first?["count"].flatMap(Int.init) ?? 0
        if total == 0 { return true }
        let authorized = try database.rows(
            """
            SELECT COUNT(*) AS count FROM memory_edge_citation ec
            JOIN memory_citation c ON c.id = ec.citation_id
            JOIN memory_source s ON s.id = c.source_id
            WHERE ec.edge_id = ? AND s.authorization = 'authorized'
              AND s.revision = c.source_revision
            """,
            [.text(edgeID.youziSQLite)]
        ).first?["count"].flatMap(Int.init) ?? 0
        return authorized > 0
    }

    func reindexNode(id: String) throws {
        guard let uuid = UUID(uuidString: id) else { throw YouziMemoryRepositoryError.integrityViolation }
        try reindexNode(id: uuid)
    }

    func reindexNode(id: UUID) throws {
        try database.execute("DELETE FROM memory_fts WHERE node_id = ?", [.text(id.youziSQLite)])
        guard let node = try node(id: id), node.deletedAt == nil,
              node.state != .forgotten, node.state != .superseded,
              try hasAuthorizedCitationOrManual(nodeID: id)
        else { return }
        try database.execute(
            "INSERT INTO memory_fts(node_id, label, content) VALUES (?, ?, ?)",
            [.text(id.youziSQLite), .text(node.label), .text(node.content)]
        )
    }

    func audit(
        action: String,
        targetID: UUID,
        relatedID: UUID?,
        before: Int?,
        after: Int?,
        requestID: UUID?,
        at: Date
    ) throws {
        try database.execute(
            """
            INSERT INTO memory_audit
              (id, action, target_id, related_id, before_revision, after_revision,
               request_id, occurred_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(uuid().youziSQLite), .text(action), .text(targetID.youziSQLite),
                relatedID.map { .text($0.youziSQLite) } ?? .null,
                before.map { .integer(Int64($0)) } ?? .null,
                after.map { .integer(Int64($0)) } ?? .null,
                requestID.map { .text($0.youziSQLite) } ?? .null,
                at.youziSQLite
            ]
        )
    }
}

private extension YouziMemoryRepository {
    static func bounded(_ value: String, maximum: Int) -> String {
        value.count <= maximum ? value : String(value.prefix(maximum))
    }

    static func redact(_ value: String) -> String {
        var result = value
        if result.range(of: "-----BEGIN ", options: .caseInsensitive) != nil,
           result.range(of: "PRIVATE KEY-----", options: .caseInsensitive) != nil {
            return "[已隐藏的私钥]"
        }
        let patterns = [
            "(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+",
            "(?i)((?:api[_-]?key|token|password|secret)\\s*[:=]\\s*)[^\\s,;]+",
            "(?i)sk-[A-Za-z0-9_-]{8,}"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let template = pattern.hasPrefix("(?i)sk-") ? "[已隐藏]" : "$1[已隐藏]"
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    static func validChecksum(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func stableUUID(_ seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    static func segmentOrder(
        _ lhs: YouziMemoryIngestionSegmentReference,
        _ rhs: YouziMemoryIngestionSegmentReference
    ) -> Bool {
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return uuidOrder(lhs.id, rhs.id)
    }

    static func canonicalKey(_ value: String) -> String {
        let folded = redact(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let components = folded.split(whereSeparator: { $0.isWhitespace })
        let normalized = components.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded(normalized, maximum: 300)
    }

    static func ftsQuery(from value: String) -> String {
        let sanitized = value.replacingOccurrences(of: "\"", with: "\"\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "" : "\"\(sanitized)\""
    }

    static func sourceKind(_ value: YouziCitationSourceType) -> YouziMemorySourceKind {
        switch value {
        case .chat: .chat
        case .workspaceFile: .workspaceFile
        case .projectFile: .projectFile
        case .manualImport: .manualFile
        case .connector: .connector
        case .artifact: .artifact
        }
    }

    static func authorization(_ value: YouziCitationAuthorizationState) -> YouziMemorySourceAuthorization {
        switch value {
        case .authorized: .authorized
        case .revoked: .revoked
        case .sourceUnavailable: .unavailable
        case .deleted: .deleted
        }
    }

    static func scope(_ value: YouziMemoryScope) -> (YouziMemoryScopeRecord, YouziMemorySensitivity) {
        switch value {
        case .personal: (.personal, .personal)
        case let .project(id): (.project(id), .ordinary)
        case let .workspace(id): (.workspace(id), .ordinary)
        case .sensitiveSealed: (.personal, .sealed)
        }
    }

    static func nodeKind(_ value: YouziMemoryNodeKind) -> YouziMemoryRecordKind {
        switch value {
        case .user: .user
        case .person: .person
        case .organization: .organization
        case .location: .location
        case .project: .project
        case .topic: .topic
        case .preference: .preference
        case .goal: .goal
        case .habit: .habit
        case .event: .event
        case .file: .file
        case .artifact: .artifact
        }
    }

    static func state(_ value: YouziMemoryState) -> YouziMemoryRecordState {
        switch value {
        case .proposed: .proposed
        case .awaitingConfirmation: .awaitingConfirmation
        case .confirmed: .confirmed
        case .superseded: .superseded
        case .forgotten: .forgotten
        }
    }

    static func relation(_ value: YouziMemoryRelation) -> YouziMemoryRelationKind {
        switch value {
        case .knows: .knows
        case .belongsTo: .belongsTo
        case .likes: .likes
        case .avoids: .avoids
        case .responsibleFor: .responsibleFor
        case .participatesIn: .participatesIn
        case .dependsOn: .dependsOn
        case .happenedAt: .happenedAt
        case .sourcedFrom: .sourcedFrom
        case .replaces: .replaces
        case .conflictsWith: .conflictsWith
        }
    }
}

// MARK: - One-time legacy/domain import

extension YouziMemoryRepository {
    /// Imports the two historical memory representations once. This method is
    /// deliberately explicit and is not a dual-write bridge: after it returns,
    /// callers use this repository for every memory read and mutation.
    func migrateLegacy(
        library: MemoryLibrary?,
        domainNodes: [YouziMemoryNode],
        domainEdges: [YouziMemoryEdge],
        domainCitations: [YouziMemoryCitation],
        at: Date
    ) throws -> YouziMemoryMigrationResult {
        let migrationKey = "legacy-json-v1-and-domain-memory-v3"
        return try database.transaction {
            if try !database.rows(
                "SELECT migration_key FROM migration_ledger WHERE migration_key = ?",
                [.text(migrationKey)]
            ).isEmpty {
                return .init(
                    importedNodes: 0, importedEdges: 0, importedCitations: 0,
                    importedLegacyEntries: 0, wasAlreadyApplied: true
                )
            }

            var importedCitations = 0
            for legacy in domainCitations.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let sourceID = Self.stableUUID("domain-source:\(legacy.id.youziSQLite)")
                let kind = Self.sourceKind(legacy.sourceType)
                let scope: YouziMemoryScopeRecord = switch (legacy.sourceType, legacy.scopeID) {
                case (.workspaceFile, let id?): .workspace(id)
                case (.projectFile, let id?): .project(id)
                default: .personal
                }
                let source = YouziMemorySourceRecord(
                    id: sourceID,
                    kind: kind,
                    externalIdentifier: Self.bounded(legacy.sourceID, maximum: 500),
                    revision: legacy.contentChecksum.isEmpty ? "legacy" : Self.bounded(legacy.contentChecksum, maximum: 200),
                    title: Self.bounded(Self.redact(legacy.title), maximum: 300),
                    scope: scope,
                    permissionID: nil,
                    importMode: legacy.sourceType == .manualImport ? .securityScopedReference : nil,
                    // Opaque legacy locators cannot support a current fact
                    // until an owning source service revalidates them.
                    authorization: legacy.authorizationState == .authorized
                        ? .unavailable : Self.authorization(legacy.authorizationState),
                    contentChecksum: Self.validChecksum(legacy.contentChecksum) ? legacy.contentChecksum.lowercased() : nil,
                    importedAt: legacy.createdAt,
                    updatedAt: legacy.updatedAt,
                    deletedAt: legacy.authorizationState == .deleted ? legacy.updatedAt : nil
                )
                if try self.source(id: sourceID) == nil { try insertSource(source) }
                let locator = YouziMemorySourceLocator(
                    kind: .legacy,
                    key: Self.bounded(legacy.stableLocator, maximum: 800),
                    detail: "needsRevalidation",
                    ordinal: nil
                )
                let excerpt = Self.bounded(Self.redact(legacy.excerpt), maximum: Self.maximumExcerptCharacters)
                let checksum = Self.validChecksum(legacy.contentChecksum)
                    ? legacy.contentChecksum.lowercased()
                    : Self.sha256(excerpt)
                let citation = YouziMemoryCitationRecord(
                    id: legacy.id,
                    sourceID: sourceID,
                    sourceRevision: source.revision,
                    locator: locator,
                    sourceTimestamp: legacy.sourceTimestamp,
                    excerpt: source.authorization == .authorized ? excerpt : "",
                    contentChecksum: checksum,
                    createdAt: legacy.createdAt
                )
                if try self.citation(id: citation.id) == nil {
                    try insertCitation(citation)
                    importedCitations += 1
                }
            }

            var importedNodes = 0
            for legacy in domainNodes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                for citationID in legacy.citationIDs where try citation(id: citationID) == nil {
                    throw YouziMemoryRepositoryError.integrityViolation
                }
                let (scope, sensitivity) = Self.scope(legacy.scope)
                var canonical = Self.canonicalKey(legacy.content)
                if try activeNodeID(canonicalKey: canonical, scope: scope) != nil {
                    canonical += ":\(legacy.id.youziSQLite)"
                }
                let record = YouziMemoryNodeRecord(
                    id: legacy.id,
                    canonicalKey: canonical,
                    label: Self.bounded(Self.redact(legacy.label), maximum: Self.maximumLabelCharacters),
                    content: Self.bounded(Self.redact(legacy.content), maximum: Self.maximumContentCharacters),
                    kind: Self.nodeKind(legacy.kind),
                    confidence: min(max(legacy.confidence, 0), 1),
                    sensitivity: sensitivity,
                    scope: scope,
                    state: Self.state(legacy.state),
                    revision: 1,
                    validFrom: legacy.validFrom,
                    validUntil: legacy.validUntil,
                    createdAt: legacy.createdAt,
                    updatedAt: legacy.updatedAt,
                    lastConfirmedAt: legacy.lastConfirmedAt,
                    deletedAt: legacy.state == .forgotten ? legacy.updatedAt : nil,
                    mergedIntoID: nil
                )
                if try node(id: record.id) == nil {
                    try insertNode(record)
                    for citationID in legacy.citationIDs {
                        try attachCitation(citationID, toNode: record.id)
                    }
                    try reindexNode(id: record.id)
                    importedNodes += 1
                }
            }

            var importedEdges = 0
            for legacy in domainEdges.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard try node(id: legacy.sourceNodeID) != nil,
                      try node(id: legacy.targetNodeID) != nil
                else { throw YouziMemoryRepositoryError.integrityViolation }
                for citationID in legacy.citationIDs where try citation(id: citationID) == nil {
                    throw YouziMemoryRepositoryError.integrityViolation
                }
                let (scope, sensitivity) = Self.scope(legacy.scope)
                let record = YouziMemoryEdgeRecord(
                    id: legacy.id,
                    sourceNodeID: legacy.sourceNodeID,
                    targetNodeID: legacy.targetNodeID,
                    relation: Self.relation(legacy.relation),
                    explanation: Self.bounded(Self.redact(legacy.explanation), maximum: 1_000),
                    confidence: min(max(legacy.confidence, 0), 1),
                    sensitivity: sensitivity,
                    scope: scope,
                    state: Self.state(legacy.state),
                    revision: 1,
                    validFrom: legacy.validFrom,
                    validUntil: legacy.validUntil,
                    createdAt: legacy.createdAt,
                    updatedAt: legacy.updatedAt,
                    deletedAt: legacy.state == .forgotten ? legacy.updatedAt : nil
                )
                if try edge(id: record.id) == nil {
                    try insertEdge(record)
                    for citationID in legacy.citationIDs {
                        try attachCitation(citationID, toEdge: record.id)
                    }
                    importedEdges += 1
                }
            }

            var importedLegacyEntries = 0
            if let library {
                guard library.schemaVersion == 1 else {
                    throw YouziMemoryRepositoryError.migrationFailed
                }
                for entry in library.entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    let redacted = Self.bounded(Self.redact(entry.content), maximum: Self.maximumContentCharacters)
                    guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let conversationIDs = entry.sourceConversationIDs.isEmpty
                        ? [Self.stableUUID("legacy-entry-source:\(entry.id.youziSQLite)")]
                        : entry.sourceConversationIDs
                    var citationIDs: [UUID] = []
                    for conversationID in conversationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                        let sourceID = Self.stableUUID("legacy-chat:\(conversationID.youziSQLite)")
                        let source = YouziMemorySourceRecord(
                            id: sourceID, kind: entry.sourceConversationIDs.isEmpty ? .legacyMemory : .chat,
                            externalIdentifier: conversationID.youziSQLite,
                            revision: "legacy-v1", title: "旧版记忆来源", scope: .personal,
                            permissionID: nil, importMode: nil, authorization: .authorized,
                            contentChecksum: nil, importedAt: entry.createdAt,
                            updatedAt: entry.updatedAt, deletedAt: nil
                        )
                        if try self.source(id: sourceID) == nil { try insertSource(source) }
                        let citationID = Self.stableUUID("legacy-citation:\(entry.id.youziSQLite):\(conversationID.youziSQLite)")
                        let citation = YouziMemoryCitationRecord(
                            id: citationID, sourceID: sourceID, sourceRevision: source.revision,
                            locator: .init(kind: .legacy, key: conversationID.youziSQLite, detail: "conversationOnly", ordinal: nil),
                            sourceTimestamp: entry.updatedAt, excerpt: "",
                            contentChecksum: Self.sha256(redacted), createdAt: entry.createdAt
                        )
                        if try self.citation(id: citationID) == nil {
                            try insertCitation(citation)
                            importedCitations += 1
                        }
                        citationIDs.append(citationID)
                    }
                    var canonical = Self.canonicalKey(redacted)
                    if try activeNodeID(canonicalKey: canonical, scope: .personal) != nil {
                        canonical += ":\(entry.id.youziSQLite)"
                    }
                    let node = YouziMemoryNodeRecord(
                        id: entry.id, canonicalKey: canonical,
                        label: Self.bounded(redacted, maximum: Self.maximumLabelCharacters),
                        content: redacted, kind: .topic,
                        confidence: min(0.95, 0.4 + Double(max(1, entry.evidenceCount)) * 0.05),
                        sensitivity: .personal, scope: .personal,
                        state: .awaitingConfirmation, revision: 1,
                        validFrom: nil, validUntil: nil, createdAt: entry.createdAt,
                        updatedAt: entry.updatedAt, lastConfirmedAt: nil,
                        deletedAt: nil, mergedIntoID: nil
                    )
                    if try self.node(id: node.id) == nil {
                        try insertNode(node)
                        for citationID in citationIDs { try attachCitation(citationID, toNode: node.id) }
                        try reindexNode(id: node.id)
                        importedLegacyEntries += 1
                        importedNodes += 1
                    }
                }
            }

            try database.execute(
                "INSERT INTO migration_ledger(migration_key, applied_at) VALUES (?, ?)",
                [.text(migrationKey), at.youziSQLite]
            )
            guard try database.rows("PRAGMA foreign_key_check").isEmpty else {
                throw YouziMemoryRepositoryError.integrityViolation
            }
            return .init(
                importedNodes: importedNodes,
                importedEdges: importedEdges,
                importedCitations: importedCitations,
                importedLegacyEntries: importedLegacyEntries,
                wasAlreadyApplied: false
            )
        }
    }
}

// MARK: - Persistent ingestion queue

extension YouziMemoryRepository {
    func enqueueSettledConversation(
        _ request: YouziMemorySettledConversationRequest
    ) throws -> YouziMemoryIngestionJob {
        guard request.capturePolicy == .allowed else {
            throw YouziMemoryRepositoryError.sourceUnauthorized
        }
        try requireText(request.sourceRevision, maximum: 200)
        try requireText(request.title, maximum: 300)
        try requireSafeIdentifier(request.extractorVersion, maximum: 100)
        try requireSafeIdentifier(request.policyVersion, maximum: 100)
        guard !request.segments.isEmpty, request.segments.count <= 512,
              Set(request.segments.map(\.id)).count == request.segments.count,
              Set(request.segments.map(\.ordinal)).count == request.segments.count,
              request.segments.allSatisfy({ $0.ordinal >= 0 && Self.validChecksum($0.checksum) })
        else { throw YouziMemoryRepositoryError.invalidInput(.invalidChecksum) }

        let scope: YouziMemoryScopeRecord
        if let projectID = request.projectID {
            scope = .project(projectID)
        } else if let workspaceID = request.workspaceID {
            scope = .workspace(workspaceID)
        } else {
            scope = .personal
        }
        let source = YouziMemorySourceRecord(
            id: request.sourceID, kind: .chat,
            externalIdentifier: request.conversationID.youziSQLite,
            revision: request.sourceRevision, title: Self.redact(request.title),
            scope: scope, taskID: request.taskID, workspaceID: request.workspaceID,
            projectID: request.projectID, permissionID: nil, importMode: nil,
            authorization: .authorized, contentChecksum: nil,
            importedAt: request.settledAt, updatedAt: request.settledAt, deletedAt: nil
        )

        return try database.transaction {
            if let existing = try self.source(id: source.id) {
                guard existing == source else { throw YouziMemoryRepositoryError.revisionConflict }
            } else {
                try insertSource(source)
            }
            let job: YouziMemoryIngestionJob
            if let existing = try self.job(
                sourceID: source.id, sourceRevision: source.revision,
                extractorVersion: request.extractorVersion,
                policyVersion: request.policyVersion
            ) {
                let storedSegments = try ingestionSegments(jobID: existing.id)
                guard storedSegments.sorted(by: Self.segmentOrder)
                        == request.segments.sorted(by: Self.segmentOrder)
                else { throw YouziMemoryRepositoryError.revisionConflict }
                job = existing
            } else {
                job = YouziMemoryIngestionJob(
                    id: uuid(), sourceID: source.id, sourceRevision: source.revision,
                    extractorVersion: request.extractorVersion,
                    policyVersion: request.policyVersion, priority: 0,
                    state: .queued, attemptCount: 0, nextAttemptAt: nil,
                    leaseOwner: nil, leaseExpiresAt: nil, recoveryCode: nil,
                    createdAt: request.settledAt, updatedAt: request.settledAt
                )
                try insertJob(job)
                for segment in request.segments {
                    try database.execute(
                        """
                        INSERT INTO memory_ingestion_segment
                          (job_id, segment_id, checksum, ordinal)
                        VALUES (?, ?, ?, ?)
                        """,
                        [
                            .text(job.id.youziSQLite), .text(segment.id.youziSQLite),
                            .text(segment.checksum.lowercased()), .integer(Int64(segment.ordinal))
                        ]
                    )
                }
            }
            return job
        }
    }

    func ingestionSegments(jobID: UUID) throws -> [YouziMemoryIngestionSegmentReference] {
        try database.rows(
            "SELECT segment_id, checksum, ordinal FROM memory_ingestion_segment WHERE job_id = ? ORDER BY ordinal",
            [.text(jobID.youziSQLite)]
        ).map { row in
            guard let id = UUID(uuidString: row["segment_id"] ?? ""),
                  let checksum = row["checksum"], let ordinal = Int(row["ordinal"] ?? "")
            else { throw YouziMemoryRepositoryError.integrityViolation }
            return .init(id: id, checksum: checksum, ordinal: ordinal)
        }
    }

    func admit(_ admission: YouziMemoryIngestionAdmission) throws -> YouziMemoryIngestionJob {
        guard admission.captureAllowed else {
            throw YouziMemoryRepositoryError.sourceUnauthorized
        }
        var normalizedSource = admission.source
        normalizedSource.externalIdentifier = Self.redact(normalizedSource.externalIdentifier)
        normalizedSource.title = Self.redact(normalizedSource.title)
        try validate(normalizedSource)
        try requireSafeIdentifier(admission.extractorVersion, maximum: 100)
        try requireSafeIdentifier(admission.policyVersion, maximum: 100)
        guard (-100...100).contains(admission.priority),
              normalizedSource.authorization == .authorized
        else { throw YouziMemoryRepositoryError.sourceUnauthorized }
        return try database.transaction {
            let source: YouziMemorySourceRecord
            if let existing = try self.source(id: normalizedSource.id) {
                guard existing == normalizedSource else {
                    throw YouziMemoryRepositoryError.revisionConflict
                }
                source = existing
            } else {
                try insertSource(normalizedSource)
                source = normalizedSource
            }
            if let existing = try job(
                sourceID: source.id,
                sourceRevision: source.revision,
                extractorVersion: admission.extractorVersion,
                policyVersion: admission.policyVersion
            ) { return existing }
            let queued = YouziMemoryIngestionJob(
                id: uuid(), sourceID: source.id, sourceRevision: source.revision,
                extractorVersion: admission.extractorVersion,
                policyVersion: admission.policyVersion, priority: admission.priority,
                state: .queued, attemptCount: 0, nextAttemptAt: nil,
                leaseOwner: nil, leaseExpiresAt: nil, recoveryCode: nil,
                createdAt: admission.admittedAt, updatedAt: admission.admittedAt
            )
            try insertJob(queued)
            return queued
        }
    }

    func enqueue(
        sourceID: UUID,
        sourceRevision: String,
        extractorVersion: String,
        policyVersion: String,
        priority: Int,
        at: Date
    ) throws -> YouziMemoryIngestionJob {
        try requireText(sourceRevision, maximum: 200)
        try requireText(extractorVersion, maximum: 100)
        try requireText(policyVersion, maximum: 100)
        guard (-100...100).contains(priority) else {
            throw YouziMemoryRepositoryError.invalidInput(.invalidLimit)
        }
        return try database.transaction {
            guard let source = try source(id: sourceID) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard source.authorization == .authorized else {
                throw YouziMemoryRepositoryError.sourceUnauthorized
            }
            guard source.revision == sourceRevision else {
                throw YouziMemoryRepositoryError.sourceRevisionChanged
            }
            if let existing = try job(
                sourceID: sourceID,
                sourceRevision: sourceRevision,
                extractorVersion: extractorVersion,
                policyVersion: policyVersion
            ) { return existing }
            let result = YouziMemoryIngestionJob(
                id: uuid(),
                sourceID: sourceID,
                sourceRevision: sourceRevision,
                extractorVersion: extractorVersion,
                policyVersion: policyVersion,
                priority: priority,
                state: .queued,
                attemptCount: 0,
                nextAttemptAt: nil,
                leaseOwner: nil,
                leaseExpiresAt: nil,
                recoveryCode: nil,
                createdAt: at,
                updatedAt: at
            )
            try insertJob(result)
            return result
        }
    }

    func claimNext(
        workerID: String,
        leaseDuration: TimeInterval,
        at: Date
    ) throws -> YouziMemoryIngestionJob? {
        try requireSafeIdentifier(workerID, maximum: 100)
        guard leaseDuration >= 1, leaseDuration <= 3_600 else {
            throw YouziMemoryRepositoryError.invalidInput(.invalidLease)
        }
        return try database.transaction {
            try database.execute(
                """
                UPDATE memory_ingestion_job
                SET state = 'queued', lease_owner = NULL, lease_expires_at = NULL,
                    updated_at = ?
                WHERE state = 'running' AND lease_expires_at <= ?
                """,
                [at.youziSQLite, at.youziSQLite]
            )
            guard let row = try database.rows(
                """
                SELECT j.* FROM memory_ingestion_job j
                JOIN memory_source s ON s.id = j.source_id
                WHERE j.state IN ('queued', 'retryScheduled')
                  AND (j.next_attempt_at IS NULL OR j.next_attempt_at <= ?)
                  AND s.authorization = 'authorized'
                  AND s.revision = j.source_revision
                ORDER BY j.priority DESC, j.created_at, j.id
                LIMIT 1
                """,
                [at.youziSQLite]
            ).first else { return nil }
            let selected = try decodeJob(row)
            try database.execute(
                """
                UPDATE memory_ingestion_job
                SET state = 'running', attempt_count = attempt_count + 1,
                    lease_owner = ?, lease_expires_at = ?, updated_at = ?
                WHERE id = ? AND state IN ('queued', 'retryScheduled')
                """,
                [
                    .text(workerID), Date(timeInterval: leaseDuration, since: at).youziSQLite,
                    at.youziSQLite, .text(selected.id.youziSQLite)
                ]
            )
            guard database.changes == 1 else { return nil }
            return try job(id: selected.id)
        }
    }

    func settle(
        jobID: UUID,
        workerID: String,
        outcome: YouziMemoryIngestionJobState,
        recoveryCode: String?,
        retryAt: Date?,
        at: Date
    ) throws -> YouziMemoryIngestionJob {
        try requireSafeIdentifier(workerID, maximum: 100)
        guard [.completed, .failed, .cancelled, .retryScheduled].contains(outcome) else {
            throw YouziMemoryRepositoryError.operationNotPermitted
        }
        if let recoveryCode { try requireSafeIdentifier(recoveryCode, maximum: 100) }
        if outcome == .retryScheduled, retryAt == nil {
            throw YouziMemoryRepositoryError.invalidInput(.invalidLease)
        }
        return try database.transaction {
            guard let current = try job(id: jobID) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard current.state == .running, current.leaseOwner == workerID else {
                throw YouziMemoryRepositoryError.revisionConflict
            }
            try database.execute(
                """
                UPDATE memory_ingestion_job
                SET state = ?, next_attempt_at = ?, lease_owner = NULL,
                    lease_expires_at = NULL, recovery_code = ?, updated_at = ?
                WHERE id = ? AND state = 'running' AND lease_owner = ?
                """,
                [
                    .text(outcome.rawValue), retryAt.map(\.youziSQLite) ?? .null,
                    recoveryCode.map(YouziSQLiteValue.text) ?? .null, at.youziSQLite,
                    .text(jobID.youziSQLite), .text(workerID)
                ]
            )
            guard database.changes == 1, let result = try job(id: jobID) else {
                throw YouziMemoryRepositoryError.revisionConflict
            }
            return result
        }
    }

    func job(id: UUID) throws -> YouziMemoryIngestionJob? {
        try database.rows(
            "SELECT * FROM memory_ingestion_job WHERE id = ?",
            [.text(id.youziSQLite)]
        ).first.map(decodeJob)
    }

    @discardableResult
    func importFile(_ request: YouziMemoryFileImportRequest) throws -> YouziMemoryFileImportReceipt {
        try validate(request)
        return try database.transaction {
            try requireCategories(request.categoryIDs)
            let revision = request.sha256.lowercased()
            let existing = try source(
                kind: .manualFile,
                externalIdentifier: request.fileID.youziSQLite,
                revision: revision
            )
            let source: YouziMemorySourceRecord
            let alreadyImported: Bool
            if let existing {
                guard existing.permissionID == request.permissionID,
                      existing.scope == request.scope,
                      existing.importMode == request.mode,
                      existing.contentChecksum == revision,
                      try sourceCategoryIDs(sourceID: existing.id).sorted(by: Self.uuidOrder)
                        == request.categoryIDs.sorted(by: Self.uuidOrder)
                else { throw YouziMemoryRepositoryError.revisionConflict }
                source = existing
                alreadyImported = true
            } else {
                source = YouziMemorySourceRecord(
                    id: request.sourceID,
                    kind: .manualFile,
                    externalIdentifier: request.fileID.youziSQLite,
                    revision: revision,
                    title: Self.redact(request.displayName),
                    scope: request.scope,
                    permissionID: request.permissionID,
                    importMode: request.mode,
                    authorization: .authorized,
                    contentChecksum: revision,
                    importedAt: request.importedAt,
                    updatedAt: request.importedAt,
                    deletedAt: nil
                )
                try insertSource(source)
                try replaceSourceCategories(sourceID: source.id, categoryIDs: request.categoryIDs)
                alreadyImported = false
            }
            let queued: YouziMemoryIngestionJob
            if let existingJob = try job(
                sourceID: source.id,
                sourceRevision: source.revision,
                extractorVersion: request.extractorVersion,
                policyVersion: request.policyVersion
            ) {
                queued = existingJob
            } else {
                queued = YouziMemoryIngestionJob(
                    id: uuid(), sourceID: source.id, sourceRevision: source.revision,
                    extractorVersion: request.extractorVersion,
                    policyVersion: request.policyVersion, priority: 10, state: .queued,
                    attemptCount: 0, nextAttemptAt: nil, leaseOwner: nil,
                    leaseExpiresAt: nil, recoveryCode: nil,
                    createdAt: request.importedAt, updatedAt: request.importedAt
                )
                try insertJob(queued)
            }
            return .init(
                sourceID: source.id,
                jobID: queued.id,
                wasAlreadyImported: alreadyImported
            )
        }
    }

    private func insertJob(_ job: YouziMemoryIngestionJob) throws {
        try database.execute(
            """
            INSERT INTO memory_ingestion_job
              (id, source_id, source_revision, extractor_version, policy_version,
               priority, state, attempt_count, next_attempt_at, lease_owner,
               lease_expires_at, recovery_code, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(job.id.youziSQLite), .text(job.sourceID.youziSQLite),
                .text(job.sourceRevision), .text(job.extractorVersion),
                .text(job.policyVersion), .integer(Int64(job.priority)),
                .text(job.state.rawValue), .integer(Int64(job.attemptCount)),
                job.nextAttemptAt.map(\.youziSQLite) ?? .null,
                job.leaseOwner.map(YouziSQLiteValue.text) ?? .null,
                job.leaseExpiresAt.map(\.youziSQLite) ?? .null,
                job.recoveryCode.map(YouziSQLiteValue.text) ?? .null,
                job.createdAt.youziSQLite, job.updatedAt.youziSQLite
            ]
        )
    }

    private func job(
        sourceID: UUID,
        sourceRevision: String,
        extractorVersion: String,
        policyVersion: String
    ) throws -> YouziMemoryIngestionJob? {
        try database.rows(
            """
            SELECT * FROM memory_ingestion_job
            WHERE source_id = ? AND source_revision = ?
              AND extractor_version = ? AND policy_version = ?
            """,
            [
                .text(sourceID.youziSQLite), .text(sourceRevision),
                .text(extractorVersion), .text(policyVersion)
            ]
        ).first.map(decodeJob)
    }
}

// MARK: - Candidate lifecycle and FTS retrieval

extension YouziMemoryRepository {
    @discardableResult
    func propose(_ batch: YouziMemoryCandidateBatch) throws -> YouziMemoryProposalResult {
        try validate(batch)
        return try database.transaction {
            if let replay = try operationResult(key: batch.idempotencyKey) {
                return YouziMemoryProposalResult(
                    nodeIDs: replay.nodeIDs,
                    edgeIDs: replay.edgeIDs,
                    wasReplay: true
                )
            }
            guard let source = try source(id: batch.sourceID) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard source.authorization == .authorized else {
                throw YouziMemoryRepositoryError.sourceUnauthorized
            }
            guard source.revision == batch.sourceRevision else {
                throw YouziMemoryRepositoryError.sourceRevisionChanged
            }

            var nodeIDs: [UUID] = []
            for candidate in batch.nodes {
                let nodeID = try upsertCandidate(candidate, sourceID: batch.sourceID, at: batch.submittedAt)
                nodeIDs.append(nodeID)
            }
            var edgeIDs: [UUID] = []
            for candidate in batch.edges {
                try insertCandidateEdge(candidate, sourceID: batch.sourceID, at: batch.submittedAt)
                edgeIDs.append(candidate.id)
            }
            let result = YouziMemoryProposalResult(
                nodeIDs: nodeIDs,
                edgeIDs: edgeIDs,
                wasReplay: false
            )
            try database.execute(
                "INSERT INTO operation_dedup(operation_key, operation_kind, result_json, created_at) VALUES (?, 'propose', ?, ?)",
                [.text(batch.idempotencyKey), .text(try encodeJSON(result)), batch.submittedAt.youziSQLite]
            )
            return result
        }
    }

    func node(id: UUID) throws -> YouziMemoryNodeRecord? {
        try database.rows(
            "SELECT * FROM memory_node WHERE id = ?",
            [.text(id.youziSQLite)]
        ).first.map(decodeNode)
    }

    func nodes(
        ids: [UUID],
        context: YouziMemoryAccessContext
    ) throws -> [YouziMemoryNodeRecord] {
        try validate(context)
        guard ids.count <= context.maximumResults,
              Set(ids).count == ids.count
        else { throw YouziMemoryRepositoryError.invalidInput(.invalidLimit) }
        var result: [YouziMemoryNodeRecord] = []
        for id in ids {
            guard let candidate = try node(id: id), candidate.deletedAt == nil,
                  candidate.state == .confirmed || context.mayManageCandidates,
                  try contextAllows(scope: candidate.scope, sensitivity: candidate.sensitivity, context: context),
                  try hasAuthorizedCitationOrManual(nodeID: candidate.id)
            else { continue }
            result.append(candidate)
        }
        return result
    }

    func workbenchSnapshot(
        context: YouziMemoryAccessContext,
        maximumNodes: Int = 120
    ) throws -> YouziMemoryWorkbenchSnapshot {
        try validate(context)
        guard context.mayManageCandidates, (1...300).contains(maximumNodes) else {
            throw YouziMemoryRepositoryError.operationNotPermitted
        }
        let rows = try database.rows(
            """
            SELECT * FROM memory_node
            WHERE deleted_at IS NULL
              AND state IN ('confirmed', 'proposed', 'awaitingConfirmation')
            ORDER BY updated_at DESC, id
            """
        )
        var nodes: [YouziMemoryNodeRecord] = []
        for node in try rows.map(decodeNode) {
            guard try contextAllows(
                scope: node.scope, sensitivity: node.sensitivity, context: context
            ), try hasAuthorizedCitationOrManual(nodeID: node.id) else { continue }
            nodes.append(node)
            if nodes.count > maximumNodes { break }
        }
        let hasMoreNodes = nodes.count > maximumNodes
        if hasMoreNodes { nodes.removeLast(nodes.count - maximumNodes) }
        let nodeIDs = Set(nodes.map(\.id))
        let edgeRows = try database.rows(
            """
            SELECT * FROM memory_edge
            WHERE deleted_at IS NULL
              AND state IN ('confirmed', 'proposed', 'awaitingConfirmation')
            ORDER BY updated_at DESC, id
            """
        )
        var edges: [YouziMemoryEdgeRecord] = []
        for edge in try edgeRows.map(decodeEdge) {
            guard nodeIDs.contains(edge.sourceNodeID), nodeIDs.contains(edge.targetNodeID),
                  try contextAllows(
                    scope: edge.scope, sensitivity: edge.sensitivity, context: context
                  ), try hasAuthorizedCitationOrManual(edgeID: edge.id)
            else { continue }
            edges.append(edge)
        }
        var membership: [UUID: [UUID]] = [:]
        for row in try database.rows(
            "SELECT node_id, category_id FROM memory_category_membership ORDER BY node_id, category_id"
        ) {
            guard let nodeID = UUID(uuidString: row["node_id"] ?? ""),
                  nodeIDs.contains(nodeID),
                  let categoryID = UUID(uuidString: row["category_id"] ?? "")
            else { continue }
            membership[nodeID, default: []].append(categoryID)
        }
        var citationCounts: [UUID: Int] = [:]
        for node in nodes {
            let count = try database.rows(
                """
                SELECT COUNT(*) AS count FROM memory_node_citation nc
                JOIN memory_citation c ON c.id = nc.citation_id
                JOIN memory_source s ON s.id = c.source_id
                WHERE nc.node_id = ? AND s.authorization = 'authorized'
                  AND s.revision = c.source_revision
                """,
                [.text(node.id.youziSQLite)]
            ).first?["count"].flatMap(Int.init) ?? 0
            citationCounts[node.id] = count
        }
        return .init(
            nodes: nodes,
            edges: edges,
            categories: try categories(),
            nodeCategoryIDs: membership,
            citationCountByNodeID: citationCounts,
            hasMoreNodes: hasMoreNodes
        )
    }

    func relations(nodeID: UUID, context: YouziMemoryAccessContext) throws -> [YouziMemoryEdgeRecord] {
        try validate(context)
        let visibleStates = context.mayManageCandidates
            ? "('confirmed','proposed','awaitingConfirmation')" : "('confirmed')"
        let rows = try database.rows(
            """
            SELECT * FROM memory_edge
            WHERE (source_node_id = ? OR target_node_id = ?)
              AND deleted_at IS NULL AND state IN \(visibleStates)
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            [.text(nodeID.youziSQLite), .text(nodeID.youziSQLite), .integer(Int64(context.maximumResults))]
        )
        var result: [YouziMemoryEdgeRecord] = []
        for edge in try rows.map(decodeEdge) {
            guard try contextAllows(
                scope: edge.scope, sensitivity: edge.sensitivity, context: context
            ), try hasAuthorizedCitationOrManual(edgeID: edge.id) else { continue }
            result.append(edge)
        }
        return result
    }

    func search(
        query: String,
        context: YouziMemoryAccessContext
    ) throws -> [YouziMemorySearchHit] {
        try requireText(query, maximum: Self.maximumQueryCharacters)
        try validate(context)
        let ftsQuery = Self.ftsQuery(from: query)
        guard !ftsQuery.isEmpty else { return [] }
        let includeCandidates = context.mayManageCandidates ? "('confirmed','proposed','awaitingConfirmation')" : "('confirmed')"
        let rows = try database.rows(
            """
            SELECT n.*, bm25(memory_fts) AS search_rank
            FROM memory_fts
            JOIN memory_node n ON n.id = memory_fts.node_id
            WHERE memory_fts MATCH ?
              AND n.deleted_at IS NULL
              AND n.state IN \(includeCandidates)
            ORDER BY search_rank, n.updated_at DESC
            LIMIT ?
            """,
            [.text(ftsQuery), .integer(Int64(context.maximumResults * 4))]
        )
        var hits: [YouziMemorySearchHit] = []
        for row in rows {
            let node = try decodeNode(row)
            guard try contextAllows(scope: node.scope, sensitivity: node.sensitivity, context: context),
                  try hasAuthorizedCitationOrManual(nodeID: node.id)
            else { continue }
            let citations = try citationIDs(nodeID: node.id)
            let rank = Double(row["search_rank"] ?? "0") ?? 0
            hits.append(.init(node: node, rank: rank, citationIDs: citations))
            if hits.count == context.maximumResults { break }
        }
        return hits
    }

    @discardableResult
    func confirmNode(
        id: UUID,
        expectedRevision: Int,
        requestID: UUID,
        at: Date
    ) throws -> YouziMemoryNodeRecord {
        try database.transaction {
            guard var existing = try node(id: id) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard existing.revision == expectedRevision else {
                throw YouziMemoryRepositoryError.revisionConflict
            }
            guard existing.state == .proposed || existing.state == .awaitingConfirmation else {
                throw YouziMemoryRepositoryError.operationNotPermitted
            }
            let next = existing.revision + 1
            try database.execute(
                "UPDATE memory_node SET state = 'confirmed', revision = ?, updated_at = ?, last_confirmed_at = ? WHERE id = ? AND revision = ?",
                [.integer(Int64(next)), at.youziSQLite, at.youziSQLite, .text(id.youziSQLite), .integer(Int64(expectedRevision))]
            )
            guard database.changes == 1 else { throw YouziMemoryRepositoryError.revisionConflict }
            try audit(action: "confirm", targetID: id, relatedID: nil, before: expectedRevision, after: next, requestID: requestID, at: at)
            try reindexNode(id: id)
            existing.state = .confirmed
            existing.revision = next
            existing.updatedAt = at
            existing.lastConfirmedAt = at
            return existing
        }
    }

    /// Replaces a node's category membership with optimistic concurrency.
    /// Classification never changes scope, sensitivity, evidence, or state.
    @discardableResult
    func classifyNode(
        id: UUID,
        expectedRevision: Int,
        categoryIDs: [UUID],
        requestID: UUID,
        at: Date
    ) throws -> YouziMemoryNodeRecord {
        guard expectedRevision > 0, categoryIDs.count <= 20,
              Set(categoryIDs).count == categoryIDs.count
        else { throw YouziMemoryRepositoryError.invalidInput(.invalidRevision) }
        return try database.transaction {
            guard var existing = try node(id: id), existing.deletedAt == nil,
                  existing.state != .forgotten, existing.state != .superseded
            else { throw YouziMemoryRepositoryError.recordNotFound }
            guard existing.revision == expectedRevision else {
                throw YouziMemoryRepositoryError.revisionConflict
            }
            try requireCategories(categoryIDs)
            try database.execute(
                "DELETE FROM memory_category_membership WHERE node_id = ?",
                [.text(id.youziSQLite)]
            )
            for categoryID in categoryIDs {
                try database.execute(
                    "INSERT INTO memory_category_membership(category_id, node_id) VALUES (?, ?)",
                    [.text(categoryID.youziSQLite), .text(id.youziSQLite)]
                )
            }
            let next = existing.revision + 1
            try database.execute(
                "UPDATE memory_node SET revision = ?, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL",
                [
                    .integer(Int64(next)), at.youziSQLite,
                    .text(id.youziSQLite), .integer(Int64(expectedRevision))
                ]
            )
            guard database.changes == 1 else {
                throw YouziMemoryRepositoryError.revisionConflict
            }
            try audit(
                action: "classify_node", targetID: id, relatedID: nil,
                before: expectedRevision, after: next,
                requestID: requestID, at: at
            )
            existing.revision = next
            existing.updatedAt = at
            return existing
        }
    }

    @discardableResult
    func revokeCandidate(
        id: UUID,
        expectedRevision: Int,
        requestID: UUID,
        at: Date
    ) throws -> YouziMemoryNodeRecord {
        try database.transaction {
            guard var existing = try node(id: id) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard existing.revision == expectedRevision else {
                throw YouziMemoryRepositoryError.revisionConflict
            }
            guard existing.state == .proposed || existing.state == .awaitingConfirmation else {
                throw YouziMemoryRepositoryError.operationNotPermitted
            }
            let next = existing.revision + 1
            try database.execute(
                "UPDATE memory_node SET state = 'forgotten', revision = ?, updated_at = ?, deleted_at = ? WHERE id = ? AND revision = ?",
                [.integer(Int64(next)), at.youziSQLite, at.youziSQLite, .text(id.youziSQLite), .integer(Int64(expectedRevision))]
            )
            try database.execute("DELETE FROM memory_fts WHERE node_id = ?", [.text(id.youziSQLite)])
            try audit(action: "revoke_candidate", targetID: id, relatedID: nil, before: expectedRevision, after: next, requestID: requestID, at: at)
            existing.state = .forgotten
            existing.revision = next
            existing.updatedAt = at
            existing.deletedAt = at
            return existing
        }
    }

    @discardableResult
    func forgetNode(
        id: UUID,
        expectedRevision: Int,
        requestID: UUID,
        at: Date
    ) throws -> YouziMemoryNodeRecord {
        try database.transaction {
            guard var existing = try node(id: id) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard existing.revision == expectedRevision, existing.deletedAt == nil else {
                throw YouziMemoryRepositoryError.revisionConflict
            }
            let next = existing.revision + 1
            try database.execute(
                """
                UPDATE memory_node
                SET state = 'forgotten', revision = ?, updated_at = ?, deleted_at = ?
                WHERE id = ? AND revision = ? AND deleted_at IS NULL
                """,
                [
                    .integer(Int64(next)), at.youziSQLite, at.youziSQLite,
                    .text(id.youziSQLite), .integer(Int64(expectedRevision))
                ]
            )
            guard database.changes == 1 else { throw YouziMemoryRepositoryError.revisionConflict }
            try database.execute(
                """
                UPDATE memory_edge
                SET state = 'forgotten', revision = revision + 1,
                    updated_at = ?, deleted_at = ?
                WHERE (source_node_id = ? OR target_node_id = ?) AND deleted_at IS NULL
                """,
                [at.youziSQLite, at.youziSQLite, .text(id.youziSQLite), .text(id.youziSQLite)]
            )
            try database.execute("DELETE FROM memory_fts WHERE node_id = ?", [.text(id.youziSQLite)])
            try audit(
                action: "forget", targetID: id, relatedID: nil,
                before: expectedRevision, after: next,
                requestID: requestID, at: at
            )
            existing.state = .forgotten
            existing.revision = next
            existing.updatedAt = at
            existing.deletedAt = at
            return existing
        }
    }

    @discardableResult
    func mergeNodes(
        primaryID: UUID,
        duplicateID: UUID,
        expectedPrimaryRevision: Int,
        expectedDuplicateRevision: Int,
        requestID: UUID,
        at: Date
    ) throws -> UUID {
        guard primaryID != duplicateID else { throw YouziMemoryRepositoryError.invalidInput(.invalidRevision) }
        return try database.transaction {
            guard let primary = try node(id: primaryID), let duplicate = try node(id: duplicateID) else {
                throw YouziMemoryRepositoryError.recordNotFound
            }
            guard primary.revision == expectedPrimaryRevision,
                  duplicate.revision == expectedDuplicateRevision,
                  primary.deletedAt == nil,
                  duplicate.deletedAt == nil
            else { throw YouziMemoryRepositoryError.revisionConflict }
            let mergeID = uuid()
            try database.execute(
                """
                INSERT INTO memory_merge
                  (id, primary_node_id, duplicate_node_id, primary_revision_before,
                   duplicate_revision_before, duplicate_state_before, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(mergeID.youziSQLite), .text(primaryID.youziSQLite),
                    .text(duplicateID.youziSQLite), .integer(Int64(primary.revision)),
                    .integer(Int64(duplicate.revision)), .text(duplicate.state.rawValue),
                    at.youziSQLite
                ]
            )
            try database.execute(
                "UPDATE memory_node SET revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?",
                [at.youziSQLite, .text(primaryID.youziSQLite), .integer(Int64(expectedPrimaryRevision))]
            )
            try database.execute(
                "UPDATE memory_node SET state = 'superseded', merged_into_id = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?",
                [.text(primaryID.youziSQLite), at.youziSQLite, .text(duplicateID.youziSQLite), .integer(Int64(expectedDuplicateRevision))]
            )
            try database.execute("DELETE FROM memory_fts WHERE node_id = ?", [.text(duplicateID.youziSQLite)])
            try audit(action: "merge", targetID: primaryID, relatedID: duplicateID, before: primary.revision, after: primary.revision + 1, requestID: requestID, at: at)
            return mergeID
        }
    }

    func undoMerge(
        mergeID: UUID,
        requestID: UUID,
        at: Date
    ) throws {
        try database.transaction {
            guard let merge = try database.rows(
                "SELECT * FROM memory_merge WHERE id = ? AND undone_at IS NULL",
                [.text(mergeID.youziSQLite)]
            ).first,
            let primaryID = UUID(uuidString: merge["primary_node_id"] ?? ""),
            let duplicateID = UUID(uuidString: merge["duplicate_node_id"] ?? ""),
            let primaryBefore = Int(merge["primary_revision_before"] ?? ""),
            let duplicateBefore = Int(merge["duplicate_revision_before"] ?? ""),
            let duplicateState = merge["duplicate_state_before"]
            else { throw YouziMemoryRepositoryError.recordNotFound }
            guard let primary = try node(id: primaryID), let duplicate = try node(id: duplicateID),
                  primary.revision == primaryBefore + 1,
                  duplicate.revision == duplicateBefore + 1,
                  duplicate.mergedIntoID == primaryID,
                  duplicate.state == .superseded
            else { throw YouziMemoryRepositoryError.revisionConflict }
            try database.execute(
                "UPDATE memory_node SET revision = revision + 1, updated_at = ? WHERE id = ?",
                [at.youziSQLite, .text(primaryID.youziSQLite)]
            )
            try database.execute(
                "UPDATE memory_node SET state = ?, merged_into_id = NULL, revision = revision + 1, updated_at = ? WHERE id = ?",
                [.text(duplicateState), at.youziSQLite, .text(duplicateID.youziSQLite)]
            )
            try database.execute(
                "UPDATE memory_merge SET undone_at = ? WHERE id = ?",
                [at.youziSQLite, .text(mergeID.youziSQLite)]
            )
            try audit(action: "undo_merge", targetID: primaryID, relatedID: duplicateID, before: primary.revision, after: primary.revision + 1, requestID: requestID, at: at)
            try reindexNode(id: duplicateID)
        }
    }
}

private extension UUID {
    var youziSQLite: String { uuidString.lowercased() }
}

private extension Date {
    var youziSQLite: YouziSQLiteValue { .real(timeIntervalSince1970) }
}
