import XCTest
import CoreGraphics
import BGVisualSemanticsProcessor
@testable import BGVisualSemanticsProcessorVision

final class Phase7Tests: XCTestCase {
    
    func testVisionPreprocessor() async throws {
        let preprocessor = VisionImagePreprocessor()
        let testImage = createTestImage(width: 2000, height: 1000)
        let loaded = LoadedImage(cgImage: testImage, width: 2000, height: 1000, sourceHash: "test")
        
        let processed = try await preprocessor.preprocess(loaded, maxDimension: 1024)
        
        XCTAssertEqual(processed.width, 1024)
        XCTAssertEqual(processed.height, 512)
        XCTAssertNotNil(processed.pixelBuffer)
    }
    
    func testVisionLabelExtractor() async throws {
        let extractor = VisionLabelExtractor()
        let testImage = createTestImage(width: 100, height: 100)
        let processed = PreprocessedImage(cgImage: testImage, pixelBuffer: nil, sourceHash: "test", width: 100, height: 100)
        
        let labels = try await extractor.extractLabels(from: processed)
        // Vision might return empty for a solid color dummy image, but shouldn't throw
        XCTAssertNotNil(labels)
    }

    private func createTestImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
