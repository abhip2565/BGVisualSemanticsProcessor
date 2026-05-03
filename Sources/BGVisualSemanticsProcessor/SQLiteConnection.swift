import Foundation
import SQLite3

/// A thin wrapper over the C SQLite3 API.
final class SQLiteConnection: Sendable {
    nonisolated(unsafe) private let db: OpaquePointer

    init(location: DatabaseLocation) throws {
        var dbOptional: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX

        let path: String
        switch location {
        case .default:
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("BGVisualSemanticsProcessor", isDirectory: true)
            try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            path = dbDir.appendingPathComponent("store.sqlite").path
        case .path(let customPath):
            path = customPath
        case .inMemory:
            path = ":memory:"
        }

        if sqlite3_open_v2(path, &dbOptional, flags, nil) != SQLITE_OK {
            let reason = dbOptional.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(dbOptional)
            throw VisualSemanticsError.storageFailure(reason: "Failed to open database at \(path): \(reason)")
        }

        guard let db = dbOptional else {
            throw VisualSemanticsError.storageFailure(reason: "Failed to initialize SQLite pointer")
        }
        self.db = db

        try applyPragmas()
    }

    deinit {
        sqlite3_close(db)
    }

    private func applyPragmas() throws {
        // PRAGMAs from §6
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA temp_store = MEMORY;")
        try exec("PRAGMA busy_timeout = 5000;")
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let reason = error.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(error)
            throw VisualSemanticsError.storageFailure(reason: "SQL execution failed: \(reason). SQL: \(sql)")
        }
    }

    func prepare(query: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
            let reason = String(cString: sqlite3_errmsg(db))
            throw VisualSemanticsError.storageFailure(reason: "Failed to prepare statement: \(reason). SQL: \(query)")
        }
        return statement!
    }

    func transaction<T>(_ block: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try block()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func queryInt(_ sql: String) throws -> Int? {
        let stmt = try prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return nil
    }
    
    // Internal helper for testing/debugging
    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }
    
    var pointer: OpaquePointer { db }
}

extension SQLiteConnection {
    // Helper for binding and stepping
    static func check(_ result: Int32, db: OpaquePointer, context: String) throws {
        if result != SQLITE_OK && result != SQLITE_DONE && result != SQLITE_ROW {
            let reason = String(cString: sqlite3_errmsg(db))
            throw VisualSemanticsError.storageFailure(reason: "\(context): \(reason)")
        }
    }
}
