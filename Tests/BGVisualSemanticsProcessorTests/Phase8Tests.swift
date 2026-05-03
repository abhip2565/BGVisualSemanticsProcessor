import XCTest
import SQLite3
@testable import BGVisualSemanticsProcessor

final class Phase8Tests: XCTestCase {
    
    // MARK: - Mocks & Helpers
    
    final class MockDateProvider: DateProvider, @unchecked Sendable {
        private var _now: Date
        private let lock = NSLock()
        init(initial: Date = Date()) { self._now = initial }
        func now() -> Date { lock.withLock { _now } }
        func advance(by interval: TimeInterval) { lock.withLock { _now.addTimeInterval(interval) } }
    }
    
    actor MockFuzzPipeline: VisualSemanticsPipeline {
        func process(_ context: PipelineContext) async throws -> PipelineOutput {
            // Simulate variable light work
            try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000...50_000))
            return PipelineOutput(
                sourceHash: "hash-\(context.itemID)",
                modelVersion: "fuzz-v1",
                imageType: .photo,
                labels: [],
                quality: nil,
                embedding: nil
            )
        }
    }
    
    private func createTestProcessor(dbLocation: DatabaseLocation = .inMemory, batchSize: Int = 10, dateProvider: DateProvider? = nil) throws -> BGVisualSemanticsProcessor {
        let config = try VisualSemanticsConfiguration(
            databaseLocation: dbLocation,
            foregroundBatchSize: batchSize,
            purgeUnconsumedExpiredResults: true
        )
        return try BGVisualSemanticsProcessor(
            config: config,
            pipeline: MockFuzzPipeline(),
            dateProvider: dateProvider ?? SystemDateProvider()
        )
    }

    // MARK: - Edge Fuzz & Stress Tests
    
    func testHighVolumeEndToEnd() async throws {
        let processor = try createTestProcessor(batchSize: 50)
        let totalItems = 1000
        
        var requests: [EnqueueRequest] = []
        for i in 0..<totalItems {
            // Mix priorities
            let priority: JobPriority = i % 10 == 0 ? .high : (i % 5 == 0 ? .low : .normal)
            requests.append(EnqueueRequest(itemID: "item-\(i)", source: .fileURL(path: "p"), priority: priority))
        }
        
        // Enqueue in batches to simulate realistic load
        for batch in requests.chunked(into: 100) {
            let outcome = try await processor.enqueue(Array(batch))
            XCTAssertEqual(outcome.enqueued.count, 100)
        }
        
        let pendingCount = try await processor.diagnosticPendingCount()
        XCTAssertEqual(pendingCount, totalItems)
        
        // Drain until empty
        var totalProcessed = 0
        while totalProcessed < totalItems {
            let summary = try await processor.drain(mode: .foreground)
            if summary.processed == 0 { break }
            totalProcessed += summary.processed
        }
        
        XCTAssertEqual(totalProcessed, totalItems)
        
        // Verify a sample
        let results = try await processor.results(for: ["item-0", "item-999"])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results["item-0"]?.resultStatus, .completed)
    }
    
    func testConcurrentStress() async throws {
        let processor = try createTestProcessor(batchSize: 20)
        
        // We use an actor to safely collect results from concurrent tasks
        actor StressTracker {
            var errors: [Error] = []
            func recordError(_ error: Error) { errors.append(error) }
        }
        let tracker = StressTracker()
        
        // 50 concurrent enqueues + 5 concurrent drains
        await withTaskGroup(of: Void.self) { group in
            // Enqueue Tasks
            for i in 0..<50 {
                let p = processor
                group.addTask {
                    do {
                        let requests = (0..<10).map { j in
                            EnqueueRequest(itemID: "stress-\(i)-\(j)", source: .fileURL(path: "p"))
                        }
                        _ = try await p.enqueue(requests)
                    } catch {
                        await tracker.recordError(error)
                    }
                }
            }
            
            // Drain Tasks
            for _ in 0..<5 {
                let p = processor
                group.addTask {
                    do {
                        _ = try await p.drain(mode: .foreground)
                    } catch {
                        await tracker.recordError(error)
                    }
                }
            }
        }
        
        let errors = await tracker.errors
        XCTAssertTrue(errors.isEmpty, "Concurrent operations threw errors: \(errors)")
        
        // Clean up remaining
        var remaining = 1
        while remaining > 0 {
            let summary = try await processor.drain(mode: .foreground)
            remaining = summary.processed
        }
        
        let count = try await processor.diagnosticPendingCount()
        XCTAssertEqual(count, 0, "All jobs should eventually finish")
    }
    
    func testTTLSweep() async throws {
        let clock = MockDateProvider()
        let processor = try createTestProcessor(dateProvider: clock)
        
        // Enqueue & process 10 items
        let requests = (0..<10).map { EnqueueRequest(itemID: "ttl-\($0)", source: .fileURL(path: "p")) }
        _ = try await processor.enqueue(requests)
        _ = try await processor.drain(mode: .foreground)
        
        // Mark first 5 as consumed
        let toConsume = (0..<5).map { "ttl-\($0)" }
        try await processor.markConsumed(itemIDs: toConsume)
        
        // Verify they exist
        let beforeSweep = try await processor.results(for: ["ttl-0", "ttl-9"])
        XCTAssertEqual(beforeSweep.count, 2)
        
        // Advance clock past TTL (24h default)
        await clock.advance(by: 25 * 3600)
        
        // Call purge (which is normally called by the app periodically)
        try await processor.purge()
        
        // In this config, purgeUnconsumedExpiredResults = true, so ALL expired results are deleted
        let afterSweep = try await processor.results(for: ["ttl-0", "ttl-9"])
        XCTAssertEqual(afterSweep.count, 0, "All expired results should be purged")
    }
    
    func testCrashRecoverySimulated() async throws {
        // Use a file-backed DB for this test to simulate persistence across instances
        let dbDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbDir) }
        
        let dbPath = dbDir.appendingPathComponent("test.sqlite").path
        let location = DatabaseLocation.path(dbPath)
        
        // Instance 1: "Crashes" mid-flight
        do {
            let proc1 = try createTestProcessor(dbLocation: location)
            _ = try await proc1.enqueue([EnqueueRequest(itemID: "crash-1", source: .fileURL(path: "p"))])
            
            // We simulate a job stuck in 'processing' by manipulating the DB directly
            // since we can't easily kill the current process mid-drain in an XCTest.
            let connection = try SQLiteConnection(location: location)
            try connection.exec("UPDATE visual_semantics_jobs SET status = 'processing', updated_at = 0 WHERE item_id = 'crash-1';")
            
            let stuckCount = try connection.queryInt("SELECT COUNT(*) FROM visual_semantics_jobs WHERE status = 'processing';")
            XCTAssertEqual(stuckCount, 1)
        }
        
        // Instance 2: Recovers
        let proc2 = try createTestProcessor(dbLocation: location)
        
        // Wait for the async startup recovery to finish
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // The init of proc2 should reset stale jobs (since updated_at was 0, it's very old)
        // Verify it was moved back to pending
        let pendingCount = try await proc2.diagnosticPendingCount()
        XCTAssertEqual(pendingCount, 1, "Stale job should be recovered to pending")
        
        // Process it successfully
        let summary = try await proc2.drain(mode: .foreground)
        XCTAssertEqual(summary.processed, 1)
        XCTAssertEqual(summary.succeeded, 1)
    }
}

// Extension to chunk arrays for the batch test
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
