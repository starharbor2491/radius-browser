// SPDX-License-Identifier: MPL-2.0
import Foundation
import CSQLite

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(path: String) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database."
            if let pointer { sqlite3_close(pointer) }
            throw ValidationError(message)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5_000)
    }
    deinit { sqlite3_close(handle) }
}

/// One actor and one SQLite connection. A revision prevents delayed saves replacing newer state.
public actor LibraryDatabase {
    private let connection: SQLiteConnection
    private var lastRevision: UInt64 = 0
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: url.path)
        try Self.execute(connection.handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        let version = try Self.scalar(connection.handle, "PRAGMA user_version")
        guard version <= 1 else { throw ValidationError("Your Radius data was created by a newer version. It has not been changed.") }
        try Self.execute(connection.handle, "CREATE TABLE IF NOT EXISTS library (id INTEGER PRIMARY KEY CHECK(id = 1), data BLOB NOT NULL); PRAGMA user_version=1;")
    }
    public func load() throws -> LibraryState {
        var stmt: OpaquePointer?
        try prepare("SELECT data FROM library WHERE id=1", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return LibraryState() }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw databaseError() }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count <= 64 * 1024 * 1024 else { throw ValidationError("Radius data exceeds the supported size. Use recovery to export it.") }
        var state = try JSONDecoder().decode(LibraryState.self, from: Data(bytes: bytes, count: count))
        state.normalize()
        return state
    }
    public func save(_ state: LibraryState, revision: UInt64) throws {
        guard revision >= lastRevision else { return }
        let data = try JSONEncoder().encode(state)
        guard data.count <= 64 * 1024 * 1024 else { throw ValidationError("Radius data is too large to save. Export or remove older notes and bookmarks.") }
        try Self.execute(connection.handle, "BEGIN IMMEDIATE")
        do {
            var stmt: OpaquePointer?
            try prepare("INSERT INTO library(id,data) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", into: &stmt)
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let result = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, 1, buffer.baseAddress, Int32(buffer.count), transient)
            }
            guard result == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
            try Self.execute(connection.handle, "COMMIT")
            lastRevision = revision
        } catch {
            try? Self.execute(connection.handle, "ROLLBACK")
            throw error
        }
    }
    public func checkpoint() throws { try Self.execute(connection.handle, "PRAGMA wal_checkpoint(TRUNCATE)") }
    private func prepare(_ sql: String, into pointer: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &pointer, nil) == SQLITE_OK else { throw databaseError() }
    }
    private func databaseError() -> ValidationError { ValidationError(String(cString: sqlite3_errmsg(connection.handle))) }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ValidationError(String(cString: sqlite3_errmsg(db)))
        }
    }
    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ValidationError("Cannot read database version.") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ValidationError("Cannot read database version.") }
        return sqlite3_column_int(stmt, 0)
    }
}
