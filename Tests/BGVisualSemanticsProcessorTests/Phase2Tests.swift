import XCTest
import SQLite3
@testable import BGVisualSemanticsProcessor

final class Phase2Tests: XCTestCase {
    
    var connection: SQLiteConnection!
    var jobStore: JobStore!
    var resultStore: ResultStore!
    
    override func setUpWithError() throws {
        connection = try SQLiteConnection(location: .inMemory)
        jobStore = JobStore(connection: connection)
        resultStore = ResultStore(connection: connection)
    }
    
    // MARK: - Migration Tests
    
    func testMigration() throws {
        try MigrationRunner.migrate(connection: connection)
        
        // Verify tables exist
        let tables = ["schema_meta", "visual_semantics_jobs", "visual_semantics_results"]
        for table in tables {
            let count = try connection.queryInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table)';")
            XCTAssertEqual(count, 1, "Table \(table) should exist")
        }
        
        // Verify version
        let version = try connection.queryInt("SELECT value FROM schema_meta WHERE key='schema_version'")
        XCTAssertEqual(version, MigrationRunner.migrations.count)
    }
    
    func testMigrationIdempotency() throws {
        try MigrationRunner.migrate(connection: connection)
        let version1 = try connection.queryInt("SELECT value FROM schema_meta WHERE key='schema_version'")
        
        try MigrationRunner.migrate(connection: connection)
        let version2 = try connection.queryInt("SELECT value FROM schema_meta WHERE key='schema_version'")
        
        XCTAssertEqual(version1, version2)
    }
    
    func testDowngradeDetection() throws {
        try MigrationRunner.migrate(connection: connection)
        // Force version to 99
        try connection.exec("UPDATE schema_meta SET value = '99' WHERE key = 'schema_version';")
        
        XCTAssertThrowsError(try MigrationRunner.migrate(connection: connection)) { error in
            if case let VisualSemanticsError.databaseSchemaIncompatible(have, expected) = error {
                XCTAssertEqual(have, 99)
                XCTAssertEqual(expected, MigrationRunner.migrations.count)
            } else {
                XCTFail("Expected databaseSchemaIncompatible, got \(error)")
            }
        }
    }
    
    // MARK: - JobStore Tests
    
    func testClaimBatchWithPriority() async throws {
        try MigrationRunner.migrate(connection: connection)
        let now = Date()
        
        let jobLow = createJob(id: "low", itemID: "item1", priority: .low, createdAt: now)
        let jobHigh = createJob(id: "high", itemID: "item2", priority: .high, createdAt: now.addingTimeInterval(10)) // even if newer
        
        try await jobStore.insert(jobLow)
        try await jobStore.insert(jobHigh)
        
        let claimed = try await jobStore.claimBatch(limit: 1, now: now.addingTimeInterval(20))
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed.first?.jobID, "high", "High priority should be claimed first")
    }
    
    func testClaimBatchWithBackoff() async throws {
        try MigrationRunner.migrate(connection: connection)
        let now = Date()
        
        var job = createJob(id: "backoff", priority: .normal, createdAt: now)
        job.nextAttemptAt = now.addingTimeInterval(100)
        try await jobStore.insert(job)
        
        let claimed = try await jobStore.claimBatch(limit: 1, now: now)
        XCTAssertTrue(claimed.isEmpty, "Job in backoff should not be claimed")
        
        let claimedLater = try await jobStore.claimBatch(limit: 1, now: now.addingTimeInterval(101))
        XCTAssertEqual(claimedLater.count, 1)
    }
    
    func testUniquePartialIndex() async throws {
        try MigrationRunner.migrate(connection: connection)
        let now = Date()
        
        let job1 = createJob(id: "j1", itemID: "item1", status: .pending, createdAt: now)
        try await jobStore.insert(job1)
        
        // Second pending for same item should fail
        let job2 = createJob(id: "j2", itemID: "item1", status: .pending, createdAt: now)
        do {
            try await jobStore.insert(job2)
            XCTFail("Should have thrown unique constraint error")
        } catch {
            // Success
        }
        
        // After j1 completes, we can insert again
        try await jobStore.transitionToCompleted(jobID: "j1", now: now)
        let job3 = createJob(id: "j3", itemID: "item1", status: .pending, createdAt: now)
        try await jobStore.insert(job3)
    }
    
    func testCoalescePending() async throws {
        try MigrationRunner.migrate(connection: connection)
        let now = Date()
        
        try await jobStore.insert(createJob(id: "j1", itemID: "item1", priority: .low, createdAt: now))
        
        let coalesced = try await jobStore.coalescePending(itemID: "item1", priority: .high, now: now.addingTimeInterval(1))
        XCTAssertTrue(coalesced)
        
        let job = try await jobStore.selectByJobID("j1")
        XCTAssertEqual(job?.priority, .high)
        XCTAssertEqual(job?.nextAttemptAt.timeIntervalSince1970, 0)
    }
    
    func testResetStaleJobs() async throws {
        try MigrationRunner.migrate(connection: connection)
        let now = Date()
        
        var job = createJob(id: "stale", status: .processing, createdAt: now.addingTimeInterval(-1000))
        job.updatedAt = now.addingTimeInterval(-500)
        try await jobStore.insert(job)
        
        let resetCount = try await jobStore.resetStaleJobs(threshold: now.addingTimeInterval(-100), now: now)
        XCTAssertEqual(resetCount, 1)
        
        let updatedJob = try await jobStore.selectByJobID("stale")
        XCTAssertEqual(updatedJob?.status, .pending)
    }
    
    // MARK: - ResultStore Tests
    
    func testPurgeExpired() async throws {
        try MigrationRunner.migrate(connection: connection)
        let now = Date()
        
        let r1 = createResult(itemID: "i1", expiresAt: now.addingTimeInterval(-10)) // expired
        let r2 = createResult(itemID: "i2", expiresAt: now.addingTimeInterval(10))  // future
        
        try await resultStore.upsert(r1, consumed: true, now: now)
        try await resultStore.upsert(r2, consumed: false, now: now)
        
        let purged = try await resultStore.purgeExpired(now: now, purgeUnconsumed: false)
        XCTAssertEqual(purged, 1)
        
        let res2 = try await resultStore.result(forItemID: "i2")
        XCTAssertNotNil(res2)
        
        let res1 = try await resultStore.result(forItemID: "i1")
        XCTAssertNil(res1)
    }

    // MARK: - Helpers
    
    private func createJob(id: String, itemID: String = "item", priority: JobPriority = .normal, status: JobStatus = .pending, createdAt: Date = Date()) -> VisualSemanticsJob {
        return VisualSemanticsJob(
            jobID: id,
            itemID: itemID,
            source: .fileURL("/path"),
            priority: priority,
            status: status,
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: 0),
            createdAt: createdAt,
            updatedAt: createdAt,
            lastError: nil,
            ownedFilePath: nil
        )
    }
    
    private func createResult(itemID: String, expiresAt: Date) -> VisualSemanticsResult {
        return VisualSemanticsResult(
            itemID: itemID,
            jobID: "job",
            sourceHash: nil,
            modelVersion: "v1",
            resultStatus: .completed,
            imageType: nil,
            labels: [],
            quality: nil,
            embedding: nil,
            error: nil,
            createdAt: Date(),
            expiresAt: expiresAt
        )
    }
}
