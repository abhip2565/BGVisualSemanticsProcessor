import XCTest
@testable import BGVisualSemanticsProcessor

final class Phase3Tests: XCTestCase {
    
    // MARK: - ProcessingGate Tests
    
    func testProcessingGate() async {
        let gate = ProcessingGate()
        
        let firstEnter = await gate.enter()
        XCTAssertTrue(firstEnter, "First enter should succeed")
        
        let secondEnter = await gate.enter()
        XCTAssertFalse(secondEnter, "Second enter while active should fail")
        
        await gate.leave()
        
        let thirdEnter = await gate.enter()
        XCTAssertTrue(thirdEnter, "Enter after leave should succeed")
    }
    
    // MARK: - ResultBroadcaster Tests
    
    func testResultBroadcasterFanOut() async {
        let broadcaster = ResultBroadcaster()
        
        var streams: [AsyncStream<VisualSemanticsResult>] = []
        for _ in 0..<100 {
            let stream = await broadcaster.subscribe()
            streams.append(stream)
        }
        
        // Wait a tiny bit for the Task in subscribe to execute
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        let count1 = await broadcaster.subscriberCount
        XCTAssertEqual(count1, 100)
        
        // Cancel half
        streams.removeLast(50)
        
        // Wait a tiny bit for the onTermination handlers to fire
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        let count2 = await broadcaster.subscriberCount
        XCTAssertEqual(count2, 50)
        
        let result = createResult(id: "r1")
        await broadcaster.broadcast(result)
        
        // Ensure remaining 50 receive the broadcast (we check the first one as representative)
        if let stream = streams.first {
            var iterator = stream.makeAsyncIterator()
            let received = await iterator.next()
            XCTAssertEqual(received?.itemID, "r1")
        }
    }
    
    func testResultBroadcasterMemory() async {
        let broadcaster = ResultBroadcaster()
        
        for _ in 0..<1000 {
            let stream = await broadcaster.subscribe()
            // Immediately drop the stream to trigger cancellation
            _ = stream
        }
        
        // Wait for terminations
        try? await Task.sleep(nanoseconds: 100_000_000)
        let finalCount = await broadcaster.subscriberCount
        XCTAssertEqual(finalCount, 0, "All continuations should be removed")
    }
    
    // MARK: - BatchProcessor Tests
    
    func testBatchProcessorCancellation() async {
        let processor = BatchProcessor()
        
        let task = Task<Void, Error> {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        
        await processor.register(jobID: "j1", canceller: { task.cancel() })
        await processor.cancel(jobID: "j1")
        
        XCTAssertTrue(task.isCancelled, "Task should be cancelled by BatchProcessor")
        
        do {
            _ = try await task.value
            XCTFail("Task should have thrown CancellationError")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - ManagedFileStore Tests
    
    func testManagedFileStore() async throws {
        let store = try ManagedFileStore(directoryName: "TestStore-\(UUID().uuidString)")
        
        let data = "test image bytes".data(using: .utf8)!
        let path = try await store.writeData(data, suggestedExtension: "txt")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        
        let contents = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(contents, data)
        
        // Sweep test
        let data2 = "test 2".data(using: .utf8)!
        let path2 = try await store.writeData(data2, suggestedExtension: "txt")
        
        await store.sweepOrphans(referencedPaths: [path]) // Keep path, orphan path2
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path2))
        
        // Cleanup
        await store.deleteFile(atPath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    
    // MARK: - SourceHasher Tests
    
    func testSourceHasher() throws {
        let hasher = SourceHasher()
        
        // Create a temporary file to test fileURL hashing
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "data".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let fileHash = hasher.hash(for: .fileURL(path: tempURL.path))
        XCTAssertNotNil(fileHash)
        
        let assetHash = hasher.hash(for: .phAssetLocalIdentifier("id-123"))
        XCTAssertEqual(assetHash, "id-123")
        
        let dataHash = hasher.hash(for: .data(Data(repeating: 0, count: 42), suggestedExtension: "txt"))
        XCTAssertEqual(dataHash, "data-size-42")
    }
    
    // MARK: - Helpers
    
    private func createResult(id: String) -> VisualSemanticsResult {
        return VisualSemanticsResult(
            itemID: id,
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
            expiresAt: Date()
        )
    }
}
