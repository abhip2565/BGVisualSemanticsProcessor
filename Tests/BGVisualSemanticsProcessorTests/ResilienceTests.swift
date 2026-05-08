import XCTest
@testable import BGVisualSemanticsProcessor

final class ResilienceTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeProcessor(
        pipeline: VisualSemanticsPipeline,
        batchSize: Int = 5,
        concurrency: Int = 2,
        perJobTimeout: TimeInterval = 5,
        staleTimeout: TimeInterval = 2,
        maxAttempts: Int = 3
    ) throws -> BGVisualSemanticsProcessor {
        let config = try VisualSemanticsConfiguration(
            databaseLocation: .inMemory,
            foregroundBatchSize: batchSize,
            foregroundConcurrency: concurrency,
            perJobTimeout: perJobTimeout,
            maxAttempts: maxAttempts,
            staleProcessingTimeout: staleTimeout
        )
        return try BGVisualSemanticsProcessor(config: config, pipeline: pipeline)
    }

    // MARK: - A1: Auto-drain after enqueue

    func testAutoDrainAfterEnqueue() async throws {
        let pipeline = DelayPipeline(delayNs: 0)
        let processor = try makeProcessor(pipeline: pipeline)

        let stream = await processor.makeResultStream()

        // Enqueue — should trigger auto-drain without explicit drain() call
        let outcome = try await processor.enqueue([
            EnqueueRequest(itemID: "auto-1", source: .fileURL(path: "/test.jpg")),
            EnqueueRequest(itemID: "auto-2", source: .fileURL(path: "/test.jpg")),
        ])
        XCTAssertEqual(outcome.enqueued.count, 2)

        // Wait for auto-drain to complete and results to be broadcast
        var received: [String] = []
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<2 {
            if let result = await withTaskTimeout(seconds: 5, operation: { await iterator.next() }) {
                received.append(result.itemID)
            }
        }
        XCTAssertEqual(Set(received), Set(["auto-1", "auto-2"]), "Both results should arrive via auto-drain")
    }

    // MARK: - A2: Per-job timeout enforcement

    func testPerJobTimeoutCancelsHungJob() async throws {
        // Pipeline hangs for 60s — but perJobTimeout is 2s
        let pipeline = DelayPipeline(delayNs: 60_000_000_000)
        let processor = try makeProcessor(pipeline: pipeline, batchSize: 1, perJobTimeout: 2)

        try await processor.enqueue([
            EnqueueRequest(itemID: "timeout-1", source: .fileURL(path: "/test.jpg"))
        ])

        let start = CFAbsoluteTimeGetCurrent()
        let summary = try await processor.drain(mode: .foreground)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Should fail within ~2s, not 60s
        XCTAssertLessThan(elapsed, 10, "Drain should not hang beyond perJobTimeout")
        XCTAssertEqual(summary.succeeded, 0)
        XCTAssertGreaterThan(summary.failedPermanent, 0)
    }

    // MARK: - A3: Concurrency enforcement

    func testConcurrencyLimitsParallelJobs() async throws {
        let pipeline = ConcurrencyTrackingPipeline(delayNs: 200_000_000) // 0.2s per job
        let processor = try makeProcessor(pipeline: pipeline, batchSize: 5, concurrency: 2, perJobTimeout: 10)

        try await processor.enqueue([
            EnqueueRequest(itemID: "c-1", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "c-2", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "c-3", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "c-4", source: .fileURL(path: "/t.jpg")),
        ])

        let summary = try await processor.drain(mode: .foreground)
        XCTAssertEqual(summary.succeeded, 4)

        let maxConcurrent = await pipeline.peakConcurrency
        XCTAssertLessThanOrEqual(maxConcurrent, 2, "Peak concurrency should respect foregroundConcurrency=2")
    }

    // MARK: - A4: Stale PROCESSING recovery in enqueue

    func testStaleProcessingJobResetOnEnqueue() async throws {
        // Use a pipeline that hangs, and a short stale timeout
        let hangPipeline = DelayPipeline(delayNs: 60_000_000_000)
        let processor = try makeProcessor(pipeline: hangPipeline, batchSize: 1, perJobTimeout: 1, staleTimeout: 1, maxAttempts: 2)

        // Enqueue and drain — job will timeout and get marked failed/pending_retry
        try await processor.enqueue([
            EnqueueRequest(itemID: "stale-1", source: .fileURL(path: "/test.jpg"))
        ])
        _ = try await processor.drain(mode: .foreground)

        // Wait for stale timeout to pass
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Re-enqueue same item — should NOT be rejected as .itemBeingProcessed
        let outcome = try await processor.enqueue([
            EnqueueRequest(itemID: "stale-1", source: .fileURL(path: "/test.jpg"))
        ])
        // It should either be enqueued fresh or coalesced (not rejected)
        let wasAccepted = outcome.enqueued.contains("stale-1") || outcome.coalesced.contains("stale-1")
        XCTAssertTrue(wasAccepted, "Stale PROCESSING job should be reset, allowing re-enqueue. Got rejected=\(outcome.rejected.map(\.itemID))")
    }

    // MARK: - A5: Error isolation — one failure doesn't kill the batch

    func testOneFailureDoesNotBlockBatch() async throws {
        // Pipeline fails for item "fail-1" but succeeds for others
        let pipeline = SelectiveFailPipeline(failItemIDs: ["fail-1"])
        let processor = try makeProcessor(pipeline: pipeline, batchSize: 5, concurrency: 3, perJobTimeout: 5, maxAttempts: 1)

        try await processor.enqueue([
            EnqueueRequest(itemID: "fail-1", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "ok-2", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "ok-3", source: .fileURL(path: "/t.jpg")),
        ])

        let summary = try await processor.drain(mode: .foreground)

        XCTAssertEqual(summary.processed, 3)
        XCTAssertEqual(summary.succeeded, 2, "Two jobs should succeed despite one failing")
        XCTAssertEqual(summary.failedPermanent, 1, "One job should fail")

        // Verify the successful results exist
        let r2 = try await processor.result(for: "ok-2")
        XCTAssertEqual(r2?.resultStatus, .completed)
        let r3 = try await processor.result(for: "ok-3")
        XCTAssertEqual(r3?.resultStatus, .completed)
    }

    // MARK: - A6: Drain-level timeout

    func testDrainTimeoutCancelsRemainingJobs() async throws {
        // 3 jobs, each hangs for 60s. perJobTimeout=2s, so drain timeout = 2 * (3+1) = 8s
        let pipeline = DelayPipeline(delayNs: 60_000_000_000)
        let processor = try makeProcessor(pipeline: pipeline, batchSize: 3, concurrency: 3, perJobTimeout: 2)

        try await processor.enqueue([
            EnqueueRequest(itemID: "dt-1", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "dt-2", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "dt-3", source: .fileURL(path: "/t.jpg")),
        ])

        let start = CFAbsoluteTimeGetCurrent()
        let summary = try await processor.drain(mode: .foreground)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 15, "Drain should not hang forever")
        XCTAssertEqual(summary.succeeded, 0, "All jobs should have failed/timed out")
    }

    // MARK: - Combined: pipeline keeps progressing

    func testPipelineKeepsProgressingDespiteFailures() async throws {
        // Mix of instant successes, failures, and timeouts
        let pipeline = MixedPipeline()
        let processor = try makeProcessor(pipeline: pipeline, batchSize: 10, concurrency: 2, perJobTimeout: 2, maxAttempts: 1)

        // Batch 1: 3 items (1 will hang, 1 will fail, 1 will succeed)
        try await processor.enqueue([
            EnqueueRequest(itemID: "hang-1", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "fail-1", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "ok-1", source: .fileURL(path: "/t.jpg")),
        ])

        let summary = try await processor.drain(mode: .foreground)
        XCTAssertEqual(summary.processed, 3)
        XCTAssertEqual(summary.succeeded, 1)

        // Batch 2: should still work — pipeline is not stalled
        try await processor.enqueue([
            EnqueueRequest(itemID: "ok-2", source: .fileURL(path: "/t.jpg")),
            EnqueueRequest(itemID: "ok-3", source: .fileURL(path: "/t.jpg")),
        ])

        let summary2 = try await processor.drain(mode: .foreground)
        XCTAssertEqual(summary2.succeeded, 2, "Pipeline should keep working after previous failures")
    }

    // MARK: - DrainScheduler

    func testDrainSchedulerCoalesces() async {
        let scheduler = DrainScheduler()

        let first = await scheduler.trySchedule()
        XCTAssertTrue(first)

        let second = await scheduler.trySchedule()
        XCTAssertFalse(second, "Second schedule while first is active should be coalesced")

        await scheduler.clear()

        let third = await scheduler.trySchedule()
        XCTAssertTrue(third, "Schedule after clear should succeed")
    }

    // MARK: - Mock Pipelines

    actor DelayPipeline: VisualSemanticsPipeline {
        let delayNs: UInt64
        init(delayNs: UInt64) { self.delayNs = delayNs }

        func process(_ context: PipelineContext) async throws -> PipelineOutput {
            try await Task.sleep(nanoseconds: delayNs)
            return PipelineOutput(
                sourceHash: "h", modelVersion: "v1", imageType: .photo,
                labels: [VisualLabel(name: "test", confidence: 0.9, source: .heuristic(name: "mock"))],
                quality: nil, embedding: nil
            )
        }
    }

    actor ConcurrencyTrackingPipeline: VisualSemanticsPipeline {
        let delayNs: UInt64
        private var currentConcurrency = 0
        var peakConcurrency = 0

        init(delayNs: UInt64) { self.delayNs = delayNs }

        func process(_ context: PipelineContext) async throws -> PipelineOutput {
            currentConcurrency += 1
            if currentConcurrency > peakConcurrency { peakConcurrency = currentConcurrency }

            try await Task.sleep(nanoseconds: delayNs)

            currentConcurrency -= 1
            return PipelineOutput(
                sourceHash: "h", modelVersion: "v1", imageType: .photo,
                labels: [VisualLabel(name: "test", confidence: 0.9, source: .heuristic(name: "mock"))],
                quality: nil, embedding: nil
            )
        }
    }

    actor SelectiveFailPipeline: VisualSemanticsPipeline {
        let failItemIDs: Set<String>
        init(failItemIDs: [String]) { self.failItemIDs = Set(failItemIDs) }

        func process(_ context: PipelineContext) async throws -> PipelineOutput {
            if failItemIDs.contains(context.itemID) {
                throw VisualSemanticsError.pipelineFailure(reason: "deliberate test failure", isTransient: false)
            }
            return PipelineOutput(
                sourceHash: "h", modelVersion: "v1", imageType: .photo,
                labels: [VisualLabel(name: "test", confidence: 0.9, source: .heuristic(name: "mock"))],
                quality: nil, embedding: nil
            )
        }
    }

    actor MixedPipeline: VisualSemanticsPipeline {
        func process(_ context: PipelineContext) async throws -> PipelineOutput {
            if context.itemID.hasPrefix("hang") {
                try await Task.sleep(nanoseconds: 60_000_000_000) // 60s hang
            }
            if context.itemID.hasPrefix("fail") {
                throw VisualSemanticsError.pipelineFailure(reason: "deliberate failure", isTransient: false)
            }
            return PipelineOutput(
                sourceHash: "h", modelVersion: "v1", imageType: .photo,
                labels: [VisualLabel(name: "test", confidence: 0.9, source: .heuristic(name: "mock"))],
                quality: nil, embedding: nil
            )
        }
    }

    // MARK: - Helpers

    private func withTaskTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
