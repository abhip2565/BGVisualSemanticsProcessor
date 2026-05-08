import Foundation

/// Standard implementation of the visual semantics pipeline that orchestrates
/// discrete stages with structured concurrency and cancellation checks.
public struct CompositePipeline: VisualSemanticsPipeline {
    private let imageLoader: any ImageLoading
    private let preprocessor: any ImagePreprocessing
    private let labelExtractor: any VisualLabelExtracting
    private let imageTypeDetector: any ImageTypeDetecting
    private let qualityAnalyzer: (any ImageQualityAnalyzing)?
    private let embeddingProvider: (any VisualEmbeddingProviding)?
    private let maxImageDimension: Int

    public init(
        imageLoader: any ImageLoading,
        preprocessor: any ImagePreprocessing,
        labelExtractor: any VisualLabelExtracting,
        imageTypeDetector: any ImageTypeDetecting,
        qualityAnalyzer: (any ImageQualityAnalyzing)? = nil,
        embeddingProvider: (any VisualEmbeddingProviding)? = nil,
        maxImageDimension: Int = 1024
    ) {
        self.imageLoader = imageLoader
        self.preprocessor = preprocessor
        self.labelExtractor = labelExtractor
        self.imageTypeDetector = imageTypeDetector
        self.qualityAnalyzer = qualityAnalyzer
        self.embeddingProvider = embeddingProvider
        self.maxImageDimension = maxImageDimension
    }

    public func process(_ context: PipelineContext) async throws -> PipelineOutput {
        let id = String(context.itemID.prefix(8))
        let t0 = CFAbsoluteTimeGetCurrent()

        // Stage 1: Load
        try Task.checkCancellation()
        let loadedImage = try await imageLoader.loadImage(from: context.source, mode: context.modeHint)
        let loadMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[VSLib] [\(id)] stage:load done \(loadMs)ms")

        // Stage 2: Preprocess
        try Task.checkCancellation()
        let t1 = CFAbsoluteTimeGetCurrent()
        let preprocessedImage = try await preprocessor.preprocess(loadedImage, maxDimension: maxImageDimension)
        print("[VSLib] [\(id)] stage:preprocess done \(Int((CFAbsoluteTimeGetCurrent() - t1) * 1000))ms \(preprocessedImage.width)x\(preprocessedImage.height)")
        try Task.checkCancellation()

        // Stage 3: Feature Extraction (Parallel)
        let t2 = CFAbsoluteTimeGetCurrent()
        print("[VSLib] [\(id)] stage:labels start")
        async let labels = labelExtractor.extractLabels(from: preprocessedImage)
        
        async let quality: ImageQuality? = {
            if let qa = qualityAnalyzer {
                return try await qa.analyzeQuality(image: preprocessedImage)
            }
            return nil
        }()
        
        async let embedding: VisualEmbedding? = {
            if let ep = embeddingProvider {
                return try await ep.embed(image: preprocessedImage)
            }
            return nil
        }()

        // Await labels first to pass them to type detector
        let resolvedLabels = try await labels
        print("[VSLib] [\(id)] stage:labels done \(Int((CFAbsoluteTimeGetCurrent() - t2) * 1000))ms count=\(resolvedLabels.count)")
        try Task.checkCancellation()

        let t3 = CFAbsoluteTimeGetCurrent()
        async let imageType = imageTypeDetector.detectImageType(image: preprocessedImage, labels: resolvedLabels)
        
        // Assemble final output
        let output = PipelineOutput(
            sourceHash: preprocessedImage.sourceHash,
            modelVersion: labelExtractor.modelVersion,
            imageType: try await imageType,
            labels: resolvedLabels,
            quality: try await quality,
            embedding: try await embedding
        )
        print("[VSLib] [\(id)] stage:typeDetect done \(Int((CFAbsoluteTimeGetCurrent() - t3) * 1000))ms type=\(output.imageType?.rawValue ?? "nil")")
        
        try Task.checkCancellation()
        return output
    }
}
