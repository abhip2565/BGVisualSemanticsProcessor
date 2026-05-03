import Foundation

/// Main entry point for visual processing logic.
public protocol VisualSemanticsPipeline: Sendable {
    func process(_ context: PipelineContext) async throws -> PipelineOutput
}

/// Handles loading raw images from various sources.
public protocol ImageLoading: Sendable {
    func loadImage(from source: ImageSourceReference, mode: ProcessingMode) async throws -> LoadedImage
}

/// Handles resizing and pixel buffer normalization.
public protocol ImagePreprocessing: Sendable {
    func preprocess(_ image: LoadedImage, maxDimension: Int) async throws -> PreprocessedImage
}

/// Extracts semantic labels from a preprocessed image.
public protocol VisualLabelExtracting: Sendable {
    var modelVersion: String { get }
    func extractLabels(from image: PreprocessedImage) async throws -> [VisualLabel]
}

/// Detects the high-level type (screenshot, document, etc.) of an image.
public protocol ImageTypeDetecting: Sendable {
    func detectImageType(image: PreprocessedImage, labels: [VisualLabel]) async throws -> VisualImageType
}

/// Analyzes image quality metrics like sharpness and brightness.
public protocol ImageQualityAnalyzing: Sendable {
    func analyzeQuality(image: PreprocessedImage) async throws -> ImageQuality
}

/// Provides vector embeddings for visual similarity search.
public protocol VisualEmbeddingProviding: Sendable {
    var modelID: String { get }
    var dimensions: Int { get }
    func embed(image: PreprocessedImage) async throws -> VisualEmbedding
}
