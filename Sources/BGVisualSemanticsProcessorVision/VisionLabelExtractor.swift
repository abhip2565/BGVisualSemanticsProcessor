import Foundation
import Vision
import BGVisualSemanticsProcessor

/// Implementation of semantic labeling using Vision's VNClassifyImageRequest.
public final class VisionLabelExtractor: VisualLabelExtracting {
    public let modelVersion: String = "Vision.VNClassifyImageRequest.v1"
    
    public init() {}
    
    public func extractLabels(from image: PreprocessedImage) async throws -> [VisualLabel] {
        let request = VNClassifyImageRequest()
        // Use CPU if needed for better stability in restricted environments/simulators
        request.usesCPUOnly = false 
        
        let handler: VNImageRequestHandler
        if let buffer = image.pixelBuffer {
            handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        } else {
            handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        }
        
        let t0 = CFAbsoluteTimeGetCurrent()
        try handler.perform([request])
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[VSLib] VNClassifyImageRequest done \(elapsed)ms")
        
        guard let observations = request.results else {
            return []
        }
        
        return observations
            .filter { $0.confidence >= 0.05 }
            .prefix(20)
            .map { obs in
                VisualLabel(
                    name: obs.identifier,
                    confidence: Double(obs.confidence),
                    source: .vision(version: modelVersion)
                )
            }
    }
}
