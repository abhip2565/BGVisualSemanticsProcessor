import Foundation
import CoreGraphics
import Photos
import UIKit
import BGVisualSemanticsProcessor

/// Implementation of image loading using ImageIO and Photos frameworks.
public final class VisionImageLoader: ImageLoading {
    public init() {}
    
    public func loadImage(from source: ImageSourceReference, mode: ProcessingMode) async throws -> LoadedImage {
        switch source {
        case .fileURL(let path):
            return try loadFromFile(path: path)
        case .data(let data, _):
            return try loadFromData(data: data)
        case .phAssetLocalIdentifier(let identifier):
            return try await loadFromPhotos(identifier: identifier, mode: mode)
        }
    }
    
    private func loadFromFile(path: String) throws -> LoadedImage {
        guard FileManager.default.fileExists(atPath: path) else {
            throw VisualSemanticsError.imageNotFound(reason: "File not found: \(path)")
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisualSemanticsError.imageDecodeFailed(reason: "Failed to create CGImage from \(path)")
        }

        return LoadedImage(
            cgImage: cgImage,
            width: cgImage.width,
            height: cgImage.height,
            sourceHash: nil // Base hasher handles files
        )
    }
    
    private func loadFromData(data: Data) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisualSemanticsError.imageDecodeFailed(reason: "Failed to create CGImage from data")
        }
        
        return LoadedImage(
            cgImage: cgImage,
            width: cgImage.width,
            height: cgImage.height,
            sourceHash: "data-\(data.count)"
        )
    }
    
    private func loadFromPhotos(identifier: String, mode: ProcessingMode) async throws -> LoadedImage {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = assets.firstObject else {
                continuation.resume(throwing: VisualSemanticsError.imageNotFound(reason: "PHAsset not found: \(identifier)"))
                return
            }

            PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false

                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: VisualSemanticsError.imageDecodeFailed(reason: error.localizedDescription))
                    return
                }

                if let uiImage = image, let cgImage = uiImage.cgImage {
                    continuation.resume(returning: LoadedImage(
                        cgImage: cgImage,
                        width: cgImage.width,
                        height: cgImage.height,
                        sourceHash: identifier
                    ))
                } else if isDegraded {
                    return
                } else {
                    continuation.resume(throwing: VisualSemanticsError.imageDecodeFailed(reason: "Failed to get CGImage from PHAsset"))
                }
            }
        }
    }
}
