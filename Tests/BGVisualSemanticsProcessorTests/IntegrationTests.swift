import XCTest
@testable import BGVisualSemanticsProcessor
import BGVisualSemanticsProcessorVision

final class IntegrationTests: XCTestCase {
    
    func testVisionIntegration() async throws {
        let config = try VisualSemanticsConfiguration(
            databaseLocation: .inMemory,
            foregroundBatchSize: 5
        )
        
        // Hybrid pipeline: real loading/preprocessing, mock extraction
        let pipeline = CompositePipeline(
            imageLoader: VisionImageLoader(),
            preprocessor: VisionImagePreprocessor(),
            labelExtractor: MockExtractor(),
            imageTypeDetector: VisionImageTypeDetector()
        )
        
        let processor = try BGVisualSemanticsProcessor(config: config, pipeline: pipeline)
        
        let imageData = createTestImageData()
        
        let requests = [
            EnqueueRequest(itemID: "item-1", source: .data(imageData, suggestedExtension: "png")),
            EnqueueRequest(itemID: "item-2", source: .data(imageData, suggestedExtension: "png"))
        ]
        
        // 1. Enqueue
        let outcome = try await processor.enqueue(requests)
        XCTAssertEqual(outcome.enqueued.count, 2)
        
        // 2. Drain
        let summary = try await processor.drain(mode: .foreground)
        XCTAssertEqual(summary.processed, 2)
        
        // 3. Verify results
        let results = try await processor.results(for: ["item-1", "item-2"])
        XCTAssertEqual(results.count, 2)
    }

    actor MockExtractor: VisualLabelExtracting {
        nonisolated let modelVersion: String = "mock-v1"
        func extractLabels(from image: PreprocessedImage) async throws -> [VisualLabel] {
            return []
        }
    }
    
    private func createTestImageData() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1.0, green: 0, blue: 0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let cgImage = context.makeImage()!
        
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
