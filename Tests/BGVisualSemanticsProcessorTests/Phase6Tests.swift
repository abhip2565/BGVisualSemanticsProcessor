import XCTest
import BackgroundTasks
@testable import BGVisualSemanticsProcessor

final class Phase6Tests: XCTestCase {
    
    var processor: BGVisualSemanticsProcessor!
    var coordinator: BGTaskCoordinator!
    var mockPipeline: MockPipeline!
    
    override func setUpWithError() throws {
        let config = try VisualSemanticsConfiguration(databaseLocation: .inMemory)
        mockPipeline = MockPipeline()
        processor = try BGVisualSemanticsProcessor(config: config, pipeline: mockPipeline)
        coordinator = BGTaskCoordinator(processor: processor, taskIdentifier: "com.test.task")
    }
    
    func testCoordinatorInterface() async throws {
        // Since we can't easily mock BGTask which is a system-managed class,
        // we verify the coordinator can be instantiated and the code is syntactically valid.
        XCTAssertNotNil(coordinator)
    }
    
    func testBackgroundDrainTrigger() async throws {
        // Enqueue some work
        try await processor.enqueue([EnqueueRequest(itemID: "bg-item", source: .fileURL(path: "p"))])
        
        // Instead of calling handleTask (which requires a BGTask), we verify drain(mode: .background)
        // is callable and works as expected end-to-end.
        let summary = try await processor.drain(mode: .background)
        XCTAssertEqual(summary.processed, 1)
        XCTAssertEqual(summary.succeeded, 1)
        
        let result = try await processor.result(for: "bg-item")
        XCTAssertNotNil(result)
    }

    // MARK: - Mocks
    
    actor MockPipeline: VisualSemanticsPipeline {
        func process(_ context: PipelineContext) async throws -> PipelineOutput {
            return PipelineOutput(
                sourceHash: "hash",
                modelVersion: "mock-v1",
                imageType: .photo,
                labels: [],
                quality: nil,
                embedding: nil
            )
        }
    }
}
