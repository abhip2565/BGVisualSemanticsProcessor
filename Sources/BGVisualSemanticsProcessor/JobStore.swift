import Foundation
import SQLite3

/// Actor responsible for managing the job store in SQLite.
actor JobStore {
    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func insert(_ job: VisualSemanticsJob) throws {
        let sql = """
        INSERT INTO visual_semantics_jobs (
            job_id, item_id, source_kind, source_value, owned_file_path,
            priority, status, attempt_count, next_attempt_at,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }

        try bind(job: job, to: stmt)
        try SQLiteConnection.check(sqlite3_step(stmt), db: connection.pointer, context: "Failed to insert job")
    }

    func coalescePending(itemID: String, priority: JobPriority, now: Date) throws -> Bool {
        // Find existing pending job
        let selectSQL = "SELECT job_id, priority FROM visual_semantics_jobs WHERE item_id = ? AND status = 'pending';"
        let selectStmt = try connection.prepare(query: selectSQL)
        defer { sqlite3_finalize(selectStmt) }
        
        try SQLiteConnection.check(sqlite3_bind_text(selectStmt, 1, (itemID as NSString).utf8String, -1, nil), db: connection.pointer, context: "Bind itemID")
        
        if sqlite3_step(selectStmt) == SQLITE_ROW {
            let jobID = String(cString: sqlite3_column_text(selectStmt, 0))
            let existingPriority = JobPriority(rawValue: Int(sqlite3_column_int(selectStmt, 1))) ?? .normal
            
            if priority > existingPriority {
                let updateSQL = "UPDATE visual_semantics_jobs SET priority = ?, updated_at = ?, next_attempt_at = 0 WHERE job_id = ?;"
                let updateStmt = try connection.prepare(query: updateSQL)
                defer { sqlite3_finalize(updateStmt) }
                
                sqlite3_bind_int(updateStmt, 1, Int32(priority.rawValue))
                sqlite3_bind_double(updateStmt, 2, now.timeIntervalSince1970)
                sqlite3_bind_text(updateStmt, 3, (jobID as NSString).utf8String, -1, nil)
                
                try SQLiteConnection.check(sqlite3_step(updateStmt), db: connection.pointer, context: "Update job priority")
            } else {
                let updateSQL = "UPDATE visual_semantics_jobs SET updated_at = ? WHERE job_id = ?;"
                let updateStmt = try connection.prepare(query: updateSQL)
                defer { sqlite3_finalize(updateStmt) }
                
                sqlite3_bind_double(updateStmt, 1, now.timeIntervalSince1970)
                sqlite3_bind_text(updateStmt, 2, (jobID as NSString).utf8String, -1, nil)
                
                try SQLiteConnection.check(sqlite3_step(updateStmt), db: connection.pointer, context: "Update job updated_at")
            }
            return true
        }
        return false
    }

    func selectActive(itemID: String) throws -> VisualSemanticsJob? {
        let sql = "SELECT * FROM visual_semantics_jobs WHERE item_id = ? AND status IN ('pending', 'processing');"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (itemID as NSString).utf8String, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return try parseJob(from: stmt)
        }
        return nil
    }

    func claimBatch(limit: Int, now: Date) throws -> [VisualSemanticsJob] {
        return try connection.transaction {
            let selectSQL = """
            SELECT job_id FROM visual_semantics_jobs
            WHERE status = 'pending' AND next_attempt_at <= ?
            ORDER BY priority DESC, next_attempt_at ASC, created_at ASC
            LIMIT ?;
            """
            let selectStmt = try connection.prepare(query: selectSQL)
            defer { sqlite3_finalize(selectStmt) }
            
            sqlite3_bind_double(selectStmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_int(selectStmt, 2, Int32(limit))
            
            var jobIDs: [String] = []
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(selectStmt, 0))
                jobIDs.append(id)
            }
            
            if jobIDs.isEmpty {
                return []
            }
            
            let placeholders = Array(repeating: "?", count: jobIDs.count).joined(separator: ",")
            let updateSQL = "UPDATE visual_semantics_jobs SET status = 'processing', attempt_count = attempt_count + 1, updated_at = ? WHERE job_id IN (\(placeholders));"
            let updateStmt = try connection.prepare(query: updateSQL)
            defer { sqlite3_finalize(updateStmt) }
            
            sqlite3_bind_double(updateStmt, 1, now.timeIntervalSince1970)
            for (index, id) in jobIDs.enumerated() {
                sqlite3_bind_text(updateStmt, Int32(index + 2), (id as NSString).utf8String, -1, nil)
            }
            
            try SQLiteConnection.check(sqlite3_step(updateStmt), db: connection.pointer, context: "Claim jobs")
            
            // Re-select full jobs
            let finalSelectSQL = "SELECT * FROM visual_semantics_jobs WHERE job_id IN (\(placeholders));"
            let finalStmt = try connection.prepare(query: finalSelectSQL)
            defer { sqlite3_finalize(finalStmt) }
            for (index, id) in jobIDs.enumerated() {
                sqlite3_bind_text(finalStmt, Int32(index + 1), (id as NSString).utf8String, -1, nil)
            }
            
            var jobs: [VisualSemanticsJob] = []
            while sqlite3_step(finalStmt) == SQLITE_ROW {
                jobs.append(try parseJob(from: finalStmt))
            }
            return jobs
        }
    }

    func transitionToCompleted(jobID: String, now: Date) throws {
        let sql = "UPDATE visual_semantics_jobs SET status = 'completed', updated_at = ? WHERE job_id = ?;"
        try executeUpdate(sql, params: [.double(now.timeIntervalSince1970), .text(jobID)])
    }

    func transitionToFailed(jobID: String, error: PersistedJobError, now: Date) throws {
        let sql = """
        UPDATE visual_semantics_jobs 
        SET status = 'failed', updated_at = ?, 
            last_error_code = ?, last_error_message = ?, last_error_transient = ?
        WHERE job_id = ?;
        """
        try executeUpdate(sql, params: [
            .double(now.timeIntervalSince1970),
            .text(error.code),
            .text(error.message),
            .int(error.isTransient ? 1 : 0),
            .text(jobID)
        ])
    }

    func transitionToPending(jobID: String, error: PersistedJobError, nextAttemptAt: Date, now: Date) throws {
        let sql = """
        UPDATE visual_semantics_jobs 
        SET status = 'pending', updated_at = ?, next_attempt_at = ?,
            last_error_code = ?, last_error_message = ?, last_error_transient = ?
        WHERE job_id = ?;
        """
        try executeUpdate(sql, params: [
            .double(now.timeIntervalSince1970),
            .double(nextAttemptAt.timeIntervalSince1970),
            .text(error.code),
            .text(error.message),
            .int(error.isTransient ? 1 : 0),
            .text(jobID)
        ])
    }

    func transitionToCancelled(jobID: String, now: Date) throws {
        let sql = "UPDATE visual_semantics_jobs SET status = 'cancelled', updated_at = ? WHERE job_id = ?;"
        try executeUpdate(sql, params: [.double(now.timeIntervalSince1970), .text(jobID)])
    }

    func revertClaimNoAttemptBump(jobID: String, now: Date) throws {
        let sql = "UPDATE visual_semantics_jobs SET status = 'pending', attempt_count = attempt_count - 1, updated_at = ? WHERE job_id = ?;"
        try executeUpdate(sql, params: [.double(now.timeIntervalSince1970), .text(jobID)])
    }

    func resetStaleJobs(threshold: Date, now: Date) throws -> Int {
        let sql = "UPDATE visual_semantics_jobs SET status = 'pending', updated_at = ? WHERE status = 'processing' AND updated_at < ?;"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, threshold.timeIntervalSince1970)
        
        try SQLiteConnection.check(sqlite3_step(stmt), db: connection.pointer, context: "Reset stale jobs")
        return Int(sqlite3_changes(connection.pointer))
    }

    func pendingCount() throws -> Int {
        return try connection.queryInt("SELECT COUNT(*) FROM visual_semantics_jobs WHERE status = 'pending';") ?? 0
    }

    func processingCount() throws -> Int {
        return try connection.queryInt("SELECT COUNT(*) FROM visual_semantics_jobs WHERE status = 'processing';") ?? 0
    }

    func failedCount() throws -> Int {
        return try connection.queryInt("SELECT COUNT(*) FROM visual_semantics_jobs WHERE status = 'failed';") ?? 0
    }

    func allPendingIDs() throws -> [String] {
        let sql = "SELECT item_id FROM visual_semantics_jobs WHERE status = 'pending';"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return ids
    }

    func selectByJobID(_ jobID: String) throws -> VisualSemanticsJob? {
        let sql = "SELECT * FROM visual_semantics_jobs WHERE job_id = ?;"
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (jobID as NSString).utf8String, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return try parseJob(from: stmt)
        }
        return nil
    }

    // MARK: - Private Helpers

    private enum Param {
        case text(String)
        case int(Int)
        case double(Double)
        case null
    }

    private func executeUpdate(_ sql: String, params: [Param]) throws {
        let stmt = try connection.prepare(query: sql)
        defer { sqlite3_finalize(stmt) }
        
        for (index, param) in params.enumerated() {
            let pos = Int32(index + 1)
            switch param {
            case .text(let val):
                sqlite3_bind_text(stmt, pos, (val as NSString).utf8String, -1, nil)
            case .int(let val):
                sqlite3_bind_int(stmt, pos, Int32(val))
            case .double(let val):
                sqlite3_bind_double(stmt, pos, val)
            case .null:
                sqlite3_bind_null(stmt, pos)
            }
        }
        
        try SQLiteConnection.check(sqlite3_step(stmt), db: connection.pointer, context: "Update execution failed")
    }

    private func bind(job: VisualSemanticsJob, to stmt: OpaquePointer) throws {
        sqlite3_bind_text(stmt, 1, (job.jobID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (job.itemID as NSString).utf8String, -1, nil)
        
        let kind: String
        let val: String
        switch job.source {
        case .fileURL(let path):
            kind = "fileURL"
            val = path
        case .phAsset(let id):
            kind = "phAsset"
            val = id
        }
        sqlite3_bind_text(stmt, 3, (kind as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (val as NSString).utf8String, -1, nil)
        
        if let ownedPath = job.ownedFilePath {
            sqlite3_bind_text(stmt, 5, (ownedPath as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        
        sqlite3_bind_int(stmt, 6, Int32(job.priority.rawValue))
        sqlite3_bind_text(stmt, 7, (job.status.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 8, Int32(job.attemptCount))
        sqlite3_bind_double(stmt, 9, job.nextAttemptAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 10, job.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 11, job.updatedAt.timeIntervalSince1970)
    }

    private func parseJob(from stmt: OpaquePointer) throws -> VisualSemanticsJob {
        let jobID = String(cString: sqlite3_column_text(stmt, 0))
        let itemID = String(cString: sqlite3_column_text(stmt, 1))
        let kind = String(cString: sqlite3_column_text(stmt, 2))
        let val = String(cString: sqlite3_column_text(stmt, 3))
        
        let source: PersistedImageSource
        if kind == "fileURL" {
            source = .fileURL(val)
        } else {
            source = .phAsset(val)
        }
        
        let ownedFilePath: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
        let priority = JobPriority(rawValue: Int(sqlite3_column_int(stmt, 5))) ?? .normal
        let status = JobStatus(rawValue: String(cString: sqlite3_column_text(stmt, 6))) ?? .pending
        let attemptCount = Int(sqlite3_column_int(stmt, 7))
        let nextAttemptAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        
        var lastError: PersistedJobError?
        if sqlite3_column_type(stmt, 11) != SQLITE_NULL {
            let code = String(cString: sqlite3_column_text(stmt, 11))
            let msg = String(cString: sqlite3_column_text(stmt, 12))
            let transient = sqlite3_column_int(stmt, 13) != 0
            lastError = PersistedJobError(code: code, message: msg, isTransient: transient)
        }
        
        return VisualSemanticsJob(
            jobID: jobID,
            itemID: itemID,
            source: source,
            priority: priority,
            status: status,
            attemptCount: attemptCount,
            nextAttemptAt: nextAttemptAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastError: lastError,
            ownedFilePath: ownedFilePath
        )
    }
}

// Ensure internal types are available
extension JobStatus {
    init?(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "processing": self = .processing
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: return nil
        }
    }
}
