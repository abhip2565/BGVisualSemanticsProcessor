import Foundation
import BGVisualSemanticsProcessor

public extension BGVisualSemanticsProcessor {
    /// Creates a processor instance with the default Vision-backed pipeline.
    /// - Parameters:
    ///   - config: The configuration to use.
    ///   - logger: Optional custom logger.
    /// - Returns: A fully configured BGVisualSemanticsProcessor.
    static func visionProcessor(
        config: VisualSemanticsConfiguration,
        logger: any VisualSemanticsLogger = OSLogVisualSemanticsLogger()
    ) throws -> BGVisualSemanticsProcessor {
        let pipeline = CompositePipeline(
            imageLoader: VisionImageLoader(),
            preprocessor: VisionImagePreprocessor(),
            labelExtractor: VisionLabelExtractor(),
            imageTypeDetector: VisionImageTypeDetector(),
            qualityAnalyzer: VisionQualityAnalyzer(),
            embeddingProvider: VisionEmbeddingProvider(),
            maxImageDimension: config.maxImageDimension
        )
        
        return try BGVisualSemanticsProcessor(
            config: config,
            pipeline: pipeline,
            logger: logger
        )
    }
}
