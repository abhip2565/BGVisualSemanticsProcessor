import XCTest
@testable import BGVisualSemanticsProcessor

final class Phase5Tests: XCTestCase {
    
    var processor: BGVisualSemanticsProcessor!
    var mockPipeline: MockPipeline!
    
    override func setUpWithError() throws {
        let config = try VisualSemanticsConfiguration(
            databaseLocation: .inMemory,
            foregroundBatchSize: 2,
            maxAttempts: 2
        )
        mockPipeline = MockPipeline()
        processor = try BGVisualSemanticsProcessor(config: config, pipeline: mockPipeline)
    }
    
    func testEndToEndFlow() async throws {
        let request = EnqueueRequest(itemID: "item1", source: .fileURL(path: "/test.jpg"))
        
        // 1. Enqueue
        let outcome = try await processor.enqueue([request])
        XCTAssertEqual(outcome.enqueued.count, 1)
        
        // 2. Subscribe to results
        let stream = await processor.resultsStream()
        
        // 3. Drain
        let summary = try await processor.drain(mode: .foreground)
        XCTAssertEqual(summary.succeeded, 1)
        
        // 4. Verify broadcast
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next()
        XCTAssertEqual(result?.itemID, "item1")
        XCTAssertEqual(result?.resultStatus, .completed)
        
        // 5. Verify persisted result
        let persisted = try await processor.result(for: "item1")
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.resultStatus, .completed)
    }
    
    func testRetryLogic() async throws {
        await mockPipeline.setShouldFailTransient(true)
        
        let request = EnqueueRequest(itemID: "retry-item", source: .fileURL(path: "/test.jpg"))
        try await processor.enqueue([request])
        
        // First drain - should fail and move to pending (retry)
        let summary1 = try await processor.drain(mode: .foreground)
        XCTAssertEqual(summary1.succeeded, 0)
        
        // Verify job is still pending (for retry)
        // In the test, we'll check the result store is empty
        let result1 = try await processor.result(for: "retry-item")
        XCTAssertNil(result1, "Result should not be upserted for transient failure until max attempts")
        
        // Fix the pipeline
        await mockPipeline.setShouldFailTransient(false)
        
        // Second drain (simulating enough time passed for retry)
        // For testing purposes, we'd need to mock the date provider to advance time.
        // But for v1 skeleton, we'll just verify the first failure path.
    }
    
    func testDataEnqueueManagement() async throws {
        let data = "binary data".data(using: .utf8)!
        let request = EnqueueRequest(itemID: "data-item", source: .data(data, suggestedExtension: "jpg"))
        
        try await processor.enqueue([request])
        
        // Verify result
        try await processor.drain(mode: .foreground)
        let result = try await processor.result(for: "data-item")
        XCTAssertEqual(result?.resultStatus, .completed)
        
        // File should be deleted after completion (verified via side effect if we could see the filesystem)
    }

    func testDuplicateDetection() async throws {
        let requests = [
            EnqueueRequest(itemID: "dup", source: .fileURL(path: "p1")),
            EnqueueRequest(itemID: "dup", source: .fileURL(path: "p2"))
        ]
        
        do {
            _ = try await processor.enqueue(requests)
            XCTFail("Should have thrown duplicate error")
        } catch VisualSemanticsError.duplicateItemIDsInBatch(let ids) {
            XCTAssertEqual(ids, ["dup"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testPriorityCoalescing() async throws {
        // Use batch size 1 to ensure we see the priority order clearly in successive claims
        let config = try VisualSemanticsConfiguration(databaseLocation: .inMemory, foregroundBatchSize: 1)
        let p = try BGVisualSemanticsProcessor(config: config, pipeline: mockPipeline)
        
        try await p.enqueue([EnqueueRequest(itemID: "i1", source: .fileURL(path: "p"), priority: .low)])
        
        // Enqueue same item with higher priority
        let outcome = try await p.enqueue([EnqueueRequest(itemID: "i1", source: .fileURL(path: "p"), priority: .high)])
        XCTAssertEqual(outcome.coalesced.count, 1)
        
        try await p.enqueue([EnqueueRequest(itemID: "i2", source: .fileURL(path: "p"), priority: .normal)])
        
        // High priority i1 should come before normal priority i2
        // We drain twice with batch size 1
        try await p.drain(mode: .foreground)
        try await p.drain(mode: .foreground)
        
        let order = await mockPipeline.startOrder
        XCTAssertEqual(order, ["i1", "i2"], "i1 should have been boosted to high priority and processed first")
    }
    
    func testCancellation() async throws {
        // Enqueue 3 items, batch size 2
        try await processor.enqueue([
            EnqueueRequest(itemID: "item-1", source: .fileURL(path: "p")),
            EnqueueRequest(itemID: "item-2", source: .fileURL(path: "p")),
            EnqueueRequest(itemID: "item-3", source: .fileURL(path: "p"))
        ])
        
        await mockPipeline.setDelay(500_000_000) // 0.5s to keep active
        
        // Start a drain. It will claim item-1 and item-2. item-3 remains pending.
        let p = self.processor!
        let drainTask = Task {
            try await p.drain(mode: .foreground)
        }
        
        // Wait for drain to claim jobs
        try? await Task.sleep(nanoseconds: 200_000_000)
        
        // Cancel all
        let outcome = try await p.cancel(itemIDs: ["item-1", "item-2", "item-3"])
        
        // item-3 was never claimed, so it's cancelledPending
        XCTAssertTrue(outcome.cancelledPending.contains("item-3"))
        // item-1 and item-2 were claimed, so they are cancellingProcessing
        XCTAssertTrue(outcome.cancellingProcessing.contains("item-1"))
        XCTAssertTrue(outcome.cancellingProcessing.contains("item-2"))
        
        _ = try await drainTask.value
        
        // Verify item-3 has no result
        let r3 = try await p.result(for: "item-3")
        XCTAssertNil(r3)
        
        // active jobs should have failed/cancelled results
        let r1 = try await p.result(for: "item-1")
        XCTAssertEqual(r1?.resultStatus, .cancelled)
    }
    
    func testConcurrencyGating() async throws {
        try await processor.enqueue([EnqueueRequest(itemID: "i1", source: .fileURL(path: "p"))])
        
        await mockPipeline.setDelay(500_000_000) // 0.5s
        
        let p = self.processor!
        let drain1 = Task { try await p.drain(mode: .foreground) }
        
        // Wait for drain 1 to enter gate
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        let summary2 = try await processor.drain(mode: .foreground)
        XCTAssertTrue(summary2.skippedGated, "Second concurrent drain should be gated")
        
        _ = try await drain1.value
    }

    // MARK: - Mocks
    
    actor MockPipeline: VisualSemanticsPipeline {
        var shouldFailTransient = false
        var delay: UInt64 = 0
        var startOrder: [String] = []
        
        func setShouldFailTransient(_ value: Bool) { shouldFailTransient = value }
        func setDelay(_ ns: UInt64) { delay = ns }
        
        func process(_ context: PipelineContext) async throws -> PipelineOutput {
            startOrder.append(context.itemID)
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            
            if shouldFailTransient {
                throw VisualSemanticsError.pipelineFailure(reason: "transient", isTransient: true)
            }
            return PipelineOutput(
                sourceHash: "hash",
                modelVersion: "mock-v1",
                imageType: .photo,
                labels: [VisualLabel(name: "test", confidence: 0.9, source: .heuristic(name: "mock"))],
                quality: nil,
                embedding: nil
            )
        }
    }
}
