import Foundation
import CoreGraphics
import CoreVideo

/// Represents an image that has been successfully loaded into memory.
public struct LoadedImage: Sendable {
    public let cgImage: CGImage
    public let width: Int
    public let height: Int
    public let sourceHash: String?

    public init(cgImage: CGImage, width: Int, height: Int, sourceHash: String?) {
        self.cgImage = cgImage
        self.width = width
        self.height = height
        self.sourceHash = sourceHash
    }
}

/// Represents an image that has been preprocessed (resized/normalized) for analysis.
/// Marked as @unchecked Sendable because CVPixelBuffer is thread-safe for reading across threads
/// once produced, but not yet explicitly marked as Sendable in the framework.
public struct PreprocessedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelBuffer: CVPixelBuffer?
    public let sourceHash: String?
    public let width: Int
    public let height: Int

    public init(cgImage: CGImage, pixelBuffer: CVPixelBuffer?, sourceHash: String?, width: Int, height: Int) {
        self.cgImage = cgImage
        self.pixelBuffer = pixelBuffer
        self.sourceHash = sourceHash
        self.width = width
        self.height = height
    }
}

/// Context passed to the pipeline for processing.
public struct PipelineContext: Sendable {
    public let jobID: String
    public let itemID: String
    public let source: ImageSourceReference
    public let modeHint: ProcessingMode

    public init(jobID: String, itemID: String, source: ImageSourceReference, modeHint: ProcessingMode) {
        self.jobID = jobID
        self.itemID = itemID
        self.source = source
        self.modeHint = modeHint
    }
}

/// Final output produced by the visual semantics pipeline.
public struct PipelineOutput: Sendable {
    public let sourceHash: String?
    public let modelVersion: String
    public let imageType: VisualImageType?
    public let labels: [VisualLabel]
    public let quality: ImageQuality?
    public let embedding: VisualEmbedding?

    public init(
        sourceHash: String?,
        modelVersion: String,
        imageType: VisualImageType?,
        labels: [VisualLabel],
        quality: ImageQuality?,
        embedding: VisualEmbedding?
    ) {
        self.sourceHash = sourceHash
        self.modelVersion = modelVersion
        self.imageType = imageType
        self.labels = labels
        self.quality = quality
        self.embedding = embedding
    }
}
