import Foundation
import Vision
import BGVisualSemanticsProcessor

/// Implementation of semantic labeling using Vision's VNClassifyImageRequest.
///
/// Vision's `VNImageRequestHandler.perform()` is synchronous and acquires internal
/// locks for ML model loading. Running two perform() calls concurrently can deadlock.
/// All Vision work is serialized through a single serial DispatchQueue, dispatched
/// off the Swift cooperative thread pool to avoid starvation.
public final class VisionLabelExtractor: VisualLabelExtracting {
    public let modelVersion: String = "Vision.VNClassifyImageRequest.v1"

    /// Serial queue — prevents concurrent Vision perform() calls that deadlock.
    /// Shared with VisionImageTypeDetector to serialize ALL Vision work.
    static let visionQueue = DispatchQueue(
        label: "com.vault.vision.serial",
        qos: .userInitiated
    )

    public init() {}

    public func extractLabels(from image: PreprocessedImage) async throws -> [VisualLabel] {
        let cgImage = image.cgImage
        let pixelBuffer = image.pixelBuffer
        let modelVer = modelVersion

        return try await withCheckedThrowingContinuation { continuation in
            Self.visionQueue.async {
                do {
                    let request = VNClassifyImageRequest()
                    request.usesCPUOnly = false

                    let handler: VNImageRequestHandler
                    if let buffer = pixelBuffer {
                        handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
                    } else {
                        handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    }

                    let t0 = CFAbsoluteTimeGetCurrent()
                    try handler.perform([request])
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    print("[VSLib] VNClassifyImageRequest done \(elapsed)ms")

                    guard let observations = request.results else {
                        continuation.resume(returning: [])
                        return
                    }

                    let labels = Array(observations
                        .filter { $0.confidence >= 0.05 }
                        .prefix(20)
                        .map { obs in
                            VisualLabel(
                                name: obs.identifier,
                                confidence: Double(obs.confidence),
                                source: .vision(version: modelVer)
                            )
                        })
                    continuation.resume(returning: labels)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
