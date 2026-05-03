import XCTest
@testable import BGVisualSemanticsProcessor

final class Phase1Tests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testConfigurationValidation() {
        // Valid config
        XCTAssertNoThrow(try VisualSemanticsConfiguration(foregroundBatchSize: 1))
        
        // Invalid values
        XCTAssertThrowsError(try VisualSemanticsConfiguration(foregroundBatchSize: 0))
        XCTAssertThrowsError(try VisualSemanticsConfiguration(backgroundBatchSize: 0))
        XCTAssertThrowsError(try VisualSemanticsConfiguration(foregroundConcurrency: 0))
        XCTAssertThrowsError(try VisualSemanticsConfiguration(maxAttempts: 0))
        XCTAssertThrowsError(try VisualSemanticsConfiguration(perJobTimeout: 0))
    }
    
    // MARK: - Codable Tests
    
    func testImageSourceReferenceCodable() throws {
        let sources: [ImageSourceReference] = [
            .fileURL(path: "/test/path.jpg"),
            .phAssetLocalIdentifier("asset-id"),
            .data(Data([0, 1, 2]), suggestedExtension: "png")
        ]
        
        for source in sources {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(ImageSourceReference.self, from: data)
            XCTAssertEqual(source, decoded)
        }
    }
    
    func testVisualLabelSourceCodable() throws {
        let sources: [VisualLabelSource] = [
            .vision(version: "v1"),
            .coreML(modelID: "model-42"),
            .heuristic(name: "sharpness")
        ]
        
        for source in sources {
            let data = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(VisualLabelSource.self, from: data)
            XCTAssertEqual(source, decoded)
        }
    }
    
    func testForwardsCompatibility() throws {
        // Encode with a future discriminator value
        let json = """
        {
            "kind": "future_source",
            "path": "/future/path"
        }
        """.data(using: .utf8)!
        
        XCTAssertThrowsError(try JSONDecoder().decode(ImageSourceReference.self, from: json)) { error in
            if case let DecodingError.dataCorrupted(context) = error {
                XCTAssertTrue(context.debugDescription.contains("Unknown ImageSourceReference kind"))
            } else {
                XCTFail("Expected dataCorrupted error, got \(error)")
            }
        }
    }
    
    // MARK: - Retry Classifier Tests
    
    func testDefaultRetryClassifier() {
        let classifier = DefaultRetryClassifier()
        
        // Transient
        XCTAssertTrue(classifier.isTransient(VisualSemanticsError.modelUnavailable(name: "test")))
        XCTAssertTrue(classifier.isTransient(VisualSemanticsError.storageFailure(reason: "test")))
        XCTAssertTrue(classifier.isTransient(VisualSemanticsError.pipelineFailure(reason: "test", isTransient: true)))
        
        // Permanent
        XCTAssertFalse(classifier.isTransient(VisualSemanticsError.imageNotFound(reason: "test")))
        XCTAssertFalse(classifier.isTransient(VisualSemanticsError.imageDecodeFailed(reason: "test")))
        XCTAssertFalse(classifier.isTransient(VisualSemanticsError.unsupportedImageSource(reason: "test")))
        XCTAssertFalse(classifier.isTransient(VisualSemanticsError.processingCancelled))
    }
    
    // MARK: - Priority Ordering Tests
    
    func testJobPriorityOrdering() {
        XCTAssertTrue(JobPriority.low < JobPriority.normal)
        XCTAssertTrue(JobPriority.normal < JobPriority.high)
        XCTAssertTrue(JobPriority.low < JobPriority.high)
    }
}
