import Foundation
import Vision
import BGVisualSemanticsProcessor

/// Implementation of semantic labeling using Vision's VNClassifyImageRequest.
/// Vision's synchronous `perform()` is dispatched to a dedicated concurrent queue
/// to avoid starving Swift's cooperative thread pool. Cancellation is supported
/// via `withTaskCancellationHandler` so per-job timeouts can break stuck calls.
public final class VisionLabelExtractor: VisualLabelExtracting {
    public let modelVersion: String = "Vision.VNClassifyImageRequest.v1"

    private static let visionQueue = DispatchQueue(
        label: "com.vault.vision.labels",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init() {}

    public func extractLabels(from image: PreprocessedImage) async throws -> [VisualLabel] {
        let cgImage = image.cgImage
        let pixelBuffer = image.pixelBuffer
        let modelVer = modelVersion

        let box = ContinuationBox<[VisualLabel]>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard box.store(continuation) else { return }

                Self.visionQueue.async {
                    guard !box.isCancelled else { return }

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

                        guard !box.isCancelled else { return }

                        guard let observations = request.results else {
                            box.resume(returning: [])
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
                        box.resume(returning: labels)
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Thread-safe box that allows a `withTaskCancellationHandler` to resume
/// a checked continuation exactly once, even if cancellation and normal
/// completion race.
final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Stores the continuation. Returns false (and resumes with CancellationError)
    /// if already cancelled.
    func store(_ c: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            c.resume(throwing: CancellationError())
            return false
        }
        continuation = c
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    func resume(returning value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}
