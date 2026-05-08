import Foundation
import Vision
import BGVisualSemanticsProcessor

/// Detects image type using structural signals (text density, edges, aspect ratio).
/// Labels are not used — type is about how the image was produced, not its content.
public final class VisionImageTypeDetector: ImageTypeDetecting {
    public init() {}

    public func detectImageType(image: PreprocessedImage, labels: [VisualLabel]) async throws -> VisualImageType {
        let textCount = await detectTextBlockCount(image: image)
        let aspectRatio = Double(image.height) / Double(max(image.width, 1))
        let edgeStats = computeEdgeStats(image: image)

        // High text density → document or screenshot
        if textCount > 15 {
            if edgeStats.hasUniformBackground && hasScreenLikeAspectRatio(aspectRatio) {
                return .screenshot
            }
            return .document
        }

        // Moderate text with document-like proportions
        if textCount > 5 && aspectRatio > 1.2 {
            return .document
        }

        // Low edge variance + large flat color regions → graphic/illustration
        if edgeStats.edgeDensity < 0.05 && edgeStats.hasUniformBackground {
            return .graphic
        }

        // High edge complexity with natural variance → photo
        if edgeStats.edgeDensity > 0.1 {
            return .photo
        }

        // Fallback: if there's meaningful visual content, default to photo
        if textCount == 0 && edgeStats.edgeDensity > 0.02 {
            return .photo
        }

        return .unknown
    }

    private func detectTextBlockCount(image: PreprocessedImage) async -> Int {
        let cgImage = image.cgImage

        return await withCheckedContinuation { continuation in
            // Use the same serial Vision queue as VisionLabelExtractor
            // to prevent concurrent perform() deadlocks
            VisionLabelExtractor.visionQueue.async {
                let request = VNDetectTextRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    print("[VSLib] VNDetectTextRectangles failed: \(error.localizedDescription)")
                    continuation.resume(returning: 0)
                    return
                }
                continuation.resume(returning: request.results?.count ?? 0)
            }
        }
    }

    private func hasScreenLikeAspectRatio(_ ratio: Double) -> Bool {
        let common: [(Double, Double)] = [
            (16.0 / 9.0, 0.15),   // phone landscape / monitor
            (9.0 / 16.0, 0.15),   // phone portrait
            (4.0 / 3.0, 0.15),    // iPad / older monitors
            (3.0 / 4.0, 0.15),
        ]
        return common.contains { abs(ratio - $0.0) < $0.1 }
    }

    private struct EdgeStats {
        let edgeDensity: Double
        let hasUniformBackground: Bool
    }

    private func computeEdgeStats(image: PreprocessedImage) -> EdgeStats {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else {
            return EdgeStats(edgeDensity: 0, hasUniformBackground: false)
        }

        let cgImage = image.cgImage
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return EdgeStats(edgeDensity: 0, hasUniformBackground: false)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample a grid for edge detection (full scan is too expensive)
        let step = max(1, min(width, height) / 100)
        var edgePixels = 0
        var totalSampled = 0
        var histogram = [Int](repeating: 0, count: 256)

        for y in stride(from: 1, to: height - 1, by: step) {
            for x in stride(from: 1, to: width - 1, by: step) {
                let idx = y * bytesPerRow + x
                let current = Int(pixels[idx])
                let right = Int(pixels[idx + 1])
                let below = Int(pixels[idx + bytesPerRow])

                let gradient = abs(current - right) + abs(current - below)
                if gradient > 30 {
                    edgePixels += 1
                }
                totalSampled += 1
                histogram[current] += 1
            }
        }

        let edgeDensity = totalSampled > 0 ? Double(edgePixels) / Double(totalSampled) : 0

        // Uniform background: top bucket holds > 40% of sampled pixels
        let maxBucket = histogram.max() ?? 0
        let hasUniform = totalSampled > 0 && Double(maxBucket) / Double(totalSampled) > 0.4

        return EdgeStats(edgeDensity: edgeDensity, hasUniformBackground: hasUniform)
    }
}
