import Foundation
import Vision
import BGVisualSemanticsProcessor

/// Implementation of semantic labeling using Vision's VNClassifyImageRequest.
///
/// Two problems with Vision's `VNImageRequestHandler.perform()`:
/// 1. Concurrent perform() calls deadlock (internal ML model loading locks)
/// 2. A single perform() can hang indefinitely on certain images/conditions
///
/// Solution: Semaphore serializes calls + GCD deadline timer abandons stuck calls.
public final class VisionLabelExtractor: VisualLabelExtracting {
    public let modelVersion: String = "Vision.VNClassifyImageRequest.v1"

    /// Semaphore serializes ALL Vision perform() calls (shared with VisionImageTypeDetector).
    /// Unlike NSLock, can be signaled from any thread — needed when deadline timer fires.
    static let visionSemaphore = DispatchSemaphore(value: 1)

    /// Hard deadline per Vision call.
    private static let deadlineSeconds: Double = 15

    public init() {}

    public func extractLabels(from image: PreprocessedImage) async throws -> [VisualLabel] {
        let cgImage = image.cgImage
        let pixelBuffer = image.pixelBuffer
        let modelVer = modelVersion

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                Self.visionSemaphore.wait()

                let request = VNClassifyImageRequest()
                request.usesCPUOnly = false

                let handler: VNImageRequestHandler
                if let buffer = pixelBuffer {
                    handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
                } else {
                    handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                }

                let once = OnceFlag()

                // GCD deadline timer — runs on a completely independent thread
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.deadlineSeconds) {
                    if once.claim() {
                        request.cancel()
                        Self.visionSemaphore.signal()
                        print("[VSLib] ⏱ Vision classify timeout after \(Int(Self.deadlineSeconds))s — abandoning stuck perform()")
                        continuation.resume(throwing: VisionTimeoutError(operation: "VNClassifyImageRequest"))
                    }
                }

                let t0 = CFAbsoluteTimeGetCurrent()
                do {
                    try handler.perform([request])
                    let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    print("[VSLib] VNClassifyImageRequest done \(elapsed)ms")

                    if once.claim() {
                        Self.visionSemaphore.signal()
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
                    }
                } catch {
                    if once.claim() {
                        Self.visionSemaphore.signal()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

/// Thread-safe flag ensuring exactly one caller wins a race.
final class OnceFlag: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    /// Returns true only for the first caller; all subsequent calls return false.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

struct VisionTimeoutError: Error, LocalizedError {
    let operation: String
    var errorDescription: String? { "\(operation) timed out" }
}
