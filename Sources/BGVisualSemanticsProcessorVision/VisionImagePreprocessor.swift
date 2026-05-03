import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import BGVisualSemanticsProcessor

/// Implementation of image preprocessing using CoreImage.
public final class VisionImagePreprocessor: ImagePreprocessing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    
    public init() {}
    
    public func preprocess(_ image: LoadedImage, maxDimension: Int) async throws -> PreprocessedImage {
        let ciImage = CIImage(cgImage: image.cgImage)
        
        // 1. Calculate scale
        let width = Double(image.width)
        let height = Double(image.height)
        let currentMax = max(width, height)
        let scale = currentMax > Double(maxDimension) ? Double(maxDimension) / currentMax : 1.0
        
        // 2. Resize
        let resizedCI = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // 3. Render to PixelBuffer
        // For Vision, we typically want 32BGRA or 32ARGB
        let targetWidth = Int(width * scale)
        let targetHeight = Int(height * scale)
        
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw VisualSemanticsError.pipelineFailure(reason: "Failed to create CVPixelBuffer", isTransient: false)
        }
        
        context.render(resizedCI, to: buffer)
        
        // 4. Create a final CGImage for stages that prefer it
        guard let finalCG = context.createCGImage(resizedCI, from: resizedCI.extent) else {
            throw VisualSemanticsError.pipelineFailure(reason: "Failed to render final CGImage", isTransient: false)
        }
        
        return PreprocessedImage(
            cgImage: finalCG,
            pixelBuffer: buffer,
            sourceHash: image.sourceHash,
            width: targetWidth,
            height: targetHeight
        )
    }
}
