import Foundation
import BGVisualSemanticsProcessor

/// Placeholder embedding provider (not implemented for v1 core).
public final class VisionEmbeddingProvider: VisualEmbeddingProviding {
    public let modelID: String = "Vision.FeaturePrint.v1"
    public let dimensions: Int = 0
    
    public init() {}
    
    public func embed(image: PreprocessedImage) async throws -> VisualEmbedding {
        // Vision feature prints require specific iOS versions/requests
        // For v1 skeleton, we return an empty vector
        return VisualEmbedding(modelID: modelID, dimensions: 0, vector: [])
    }
}
