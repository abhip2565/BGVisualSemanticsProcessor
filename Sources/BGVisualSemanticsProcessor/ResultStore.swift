import Foundation
import SQLite3

/// Actor responsible for managing processing results in SQLite.
actor ResultStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func upsert(_ result: VisualSemanticsResult, consumed: Bool = false, now: Date) throws {
        let resultJSON = try JSONEncoder().encode(result)
        guard let jsonString = String(data: resultJSON, encoding: .utf8) else {
            throw VisualSemanticsError.storageFailure(reason: "Failed to encode result to JSON")
        }

        let sql = """
        INSERT INTO visual_semantics_results (
            item_id, job_id, result_json, result_status, consumed,
            created_at, updated_at, expires_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET
            job_id = excluded.job_id,
            result_json = excluded.result_json,
            result_status = excluded.result_status,
            consumed = excluded.consumed,
            updated_at = excluded.updated_at,
            expires_at = excluded.expires_at;
        """
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (result.itemID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (result.jobID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (jsonString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (result.resultStatus.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 5, consumed ? 1 : 0)
        sqlite3_bind_double(stmt, 6, result.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, now.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 8, result.expiresAt.timeIntervalSince1970)

        try SQLiteConnection.check(sqlite3_step(stmt), db: connection.pointer, context: "Failed to upsert result")
    }

    func markConsumed(itemIDs: [String], now: Date) throws {
        if itemIDs.isEmpty { return }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        let sql = "UPDATE visual_semantics_results SET consumed = 1, updated_at = ? WHERE item_id IN (\(placeholders));"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        for (index, id) in itemIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 2), (id as NSString).utf8String, -1, nil)
        }
        
        try SQLiteConnection.check(sqlite3_step(stmt), db: connection.pointer, context: "Mark consumed failed")
    }

    func result(forItemID itemID: String) throws -> VisualSemanticsResult? {
        let sql = "SELECT result_json FROM visual_semantics_results WHERE item_id = ?;"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (itemID as NSString).utf8String, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            let jsonString = String(cString: sqlite3_column_text(stmt, 0))
            guard let data = jsonString.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(VisualSemanticsResult.self, from: data)
        }
        return nil
    }

    func pendingResults(limit: Int) throws -> [VisualSemanticsResult] {
        let sql = "SELECT result_json FROM visual_semantics_results WHERE consumed = 0 ORDER BY created_at ASC LIMIT ?;"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int(stmt, 1, Int32(limit))
        
        var results: [VisualSemanticsResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let jsonString = String(cString: sqlite3_column_text(stmt, 0))
            if let data = jsonString.data(using: .utf8),
               let result = try? JSONDecoder().decode(VisualSemanticsResult.self, from: data) {
                results.append(result)
            }
        }
        return results
    }

    func purgeExpired(now: Date, purgeUnconsumed: Bool) throws -> Int {
        var sql = "DELETE FROM visual_semantics_results WHERE expires_at < ?"
        if !purgeUnconsumed {
            sql += " AND consumed = 1"
        }
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        
        try SQLiteConnection.check(sqlite3_step(stmt), db: connection.pointer, context: "Purge expired failed")
        return Int(sqlite3_changes(connection.pointer))
    }

    func pruneTerminalJobsOlderThan(_ threshold: Date) throws -> Int {
        // Prune jobs table of terminal jobs (completed, failed, cancelled)
        let sql = "DELETE FROM visual_semantics_jobs WHERE status NOT IN ('pending', 'processing') AND updated_at < ?;"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_double(stmt, 1, threshold.timeIntervalSince1970)
        
        try SQLiteConnection.check(sqlite3_step(stmt), db: connection.pointer, context: "Prune terminal jobs failed")
        return Int(sqlite3_changes(connection.pointer))
    }
}
