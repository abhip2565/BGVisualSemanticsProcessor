import XCTest
import CoreGraphics
@testable import BGVisualSemanticsProcessor

final class Phase4Tests: XCTestCase {
    
    // MARK: - Mocks
    
    actor MockLoader: ImageLoading {
        var shouldFail = false
        func setShouldFail(_ value: Bool) { shouldFail = value }
        func loadImage(from source: ImageSourceReference, mode: ProcessingMode) async throws -> LoadedImage {
            if shouldFail { throw VisualSemanticsError.imageNotFound(reason: "mock") }
            return LoadedImage(cgImage: createTestImage(), width: 100, height: 100, sourceHash: "hash")
        }
    }
    
    actor MockPreprocessor: ImagePreprocessing {
        var onCall: (() -> Void)?
        func setOnCall(_ block: @escaping () -> Void) { onCall = block }
        func preprocess(_ image: LoadedImage, maxDimension: Int) async throws -> PreprocessedImage {
            onCall?()
            return PreprocessedImage(cgImage: image.cgImage, pixelBuffer: nil, sourceHash: image.sourceHash, width: image.width, height: image.height)
        }
    }
    
    actor MockExtractor: VisualLabelExtracting {
        nonisolated let modelVersion: String = "mock-v1"
        var delay: UInt64 = 0
        var onStart: (() -> Void)?
        func setDelay(_ value: UInt64) { delay = value }
        func setOnStart(_ block: @escaping () -> Void) { onStart = block }
        func extractLabels(from image: PreprocessedImage) async throws -> [VisualLabel] {
            onStart?()
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            return [VisualLabel(name: "test", confidence: 0.9, source: .heuristic(name: "mock"))]
        }
    }
    
    actor MockTypeDetector: ImageTypeDetecting {
        func detectImageType(image: PreprocessedImage, labels: [VisualLabel]) async throws -> VisualImageType {
            return .photo
        }
    }
    
    actor MockQualityAnalyzer: ImageQualityAnalyzing {
        var delay: UInt64 = 0
        var onStart: (() -> Void)?
        func setDelay(_ value: UInt64) { delay = value }
        func setOnStart(_ block: @escaping () -> Void) { onStart = block }
        func analyzeQuality(image: PreprocessedImage) async throws -> ImageQuality {
            onStart?()
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            return ImageQuality(sharpness: 0.8, brightness: 0.7)
        }
    }

    // MARK: - Tests
    
    func testCompositePipelineSuccess() async throws {
        let pipeline = CompositePipeline(
            imageLoader: MockLoader(),
            preprocessor: MockPreprocessor(),
            labelExtractor: MockExtractor(),
            imageTypeDetector: MockTypeDetector(),
            qualityAnalyzer: MockQualityAnalyzer()
        )
        
        let context = PipelineContext(jobID: "j1", itemID: "i1", source: .fileURL(path: "p"), modeHint: .foreground)
        let output = try await pipeline.process(context)
        
        XCTAssertEqual(output.labels.count, 1)
        XCTAssertEqual(output.imageType, .photo)
        XCTAssertEqual(output.modelVersion, "mock-v1")
        XCTAssertNotNil(output.quality)
    }
    
    func testStageFailurePropagation() async throws {
        let loader = MockLoader()
        await loader.setShouldFail(true)
        
        let pipeline = CompositePipeline(
            imageLoader: loader,
            preprocessor: MockPreprocessor(),
            labelExtractor: MockExtractor(),
            imageTypeDetector: MockTypeDetector()
        )
        
        let context = PipelineContext(jobID: "j1", itemID: "i1", source: .fileURL(path: "p"), modeHint: .foreground)
        
        do {
            _ = try await pipeline.process(context)
            XCTFail("Should have thrown error")
        } catch VisualSemanticsError.imageNotFound {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testCancellationBetweenStages() async throws {
        let preprocessor = MockPreprocessor()
        let pipeline = CompositePipeline(
            imageLoader: MockLoader(),
            preprocessor: preprocessor,
            labelExtractor: MockExtractor(),
            imageTypeDetector: MockTypeDetector()
        )
        
        let task = Task {
            let context = PipelineContext(jobID: "j1", itemID: "i1", source: .fileURL(path: "p"), modeHint: .foreground)
            return try await pipeline.process(context)
        }
        
        await preprocessor.setOnCall {
            task.cancel()
        }
        
        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch is CancellationError {
            // Success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testParallelExecution() async throws {
        let extractor = MockExtractor()
        let analyzer = MockQualityAnalyzer()
        
        await extractor.setDelay(200_000_000) // 0.2s
        await analyzer.setDelay(200_000_000)  // 0.2s
        
        // Use an actor to track completion to ensure Sendability
        actor Tracker {
            var extractorStarted = false
            var analyzerStarted = false
            func setExtractorStarted() { extractorStarted = true }
            func setAnalyzerStarted() { analyzerStarted = true }
        }
        let tracker = Tracker()
        
        await extractor.setOnStart {
            Task { await tracker.setExtractorStarted() }
        }
        await analyzer.setOnStart {
            Task { await tracker.setAnalyzerStarted() }
        }
        
        let pipeline = CompositePipeline(
            imageLoader: MockLoader(),
            preprocessor: MockPreprocessor(),
            labelExtractor: extractor,
            imageTypeDetector: MockTypeDetector(),
            qualityAnalyzer: analyzer
        )
        
        let context = PipelineContext(jobID: "j1", itemID: "i1", source: .fileURL(path: "p"), modeHint: .foreground)
        
        let start = CFAbsoluteTimeGetCurrent()
        _ = try await pipeline.process(context)
        let duration = CFAbsoluteTimeGetCurrent() - start
        
        let extractorStarted = await tracker.extractorStarted
        let analyzerStarted = await tracker.analyzerStarted
        
        XCTAssertTrue(extractorStarted)
        XCTAssertTrue(analyzerStarted)
        XCTAssertTrue(duration < 0.35, "Pipeline stages should run in parallel. Duration: \(duration)")
    }
}

// Helper to create a dummy CGImage for testing
func createTestImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}
