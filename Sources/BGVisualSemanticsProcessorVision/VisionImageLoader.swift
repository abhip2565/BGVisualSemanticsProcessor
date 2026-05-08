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
        let shortPath = String(path.suffix(30))
        let exists = FileManager.default.fileExists(atPath: path)
        print("[VSLib] file load: \(shortPath) exists=\(exists)")
        guard exists else {
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

        let shortId = String(identifier.prefix(12))
        print("[VSLib] PHAsset load start: \(shortId) networkAllowed=\(options.isNetworkAccessAllowed)")

        return try await withCheckedThrowingContinuation { continuation in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = assets.firstObject else {
                print("[VSLib] PHAsset not found: \(shortId)")
                continuation.resume(throwing: VisualSemanticsError.imageNotFound(reason: "PHAsset not found: \(identifier)"))
                return
            }

            print("[VSLib] PHAsset found: \(shortId) pixel=\(asset.pixelWidth)x\(asset.pixelHeight)")

            var callbackCount = 0
            PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { image, info in
                callbackCount += 1
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                print("[VSLib] PHAsset callback #\(callbackCount): \(shortId) degraded=\(isDegraded) hasImage=\(image != nil)")

                if let error = info?[PHImageErrorKey] as? Error {
                    print("[VSLib] PHAsset error: \(shortId) \(error.localizedDescription)")
                    continuation.resume(throwing: VisualSemanticsError.imageDecodeFailed(reason: error.localizedDescription))
                    return
                }

                if let uiImage = image, let cgImage = uiImage.cgImage {
                    print("[VSLib] PHAsset loaded: \(shortId) size=\(cgImage.width)x\(cgImage.height)")
                    continuation.resume(returning: LoadedImage(
                        cgImage: cgImage,
                        width: cgImage.width,
                        height: cgImage.height,
                        sourceHash: identifier
                    ))
                } else if isDegraded {
                    print("[VSLib] PHAsset degraded, waiting: \(shortId)")
                    return
                } else {
                    print("[VSLib] PHAsset no image: \(shortId)")
                    continuation.resume(throwing: VisualSemanticsError.imageDecodeFailed(reason: "Failed to get CGImage from PHAsset"))
                }
            }
        }
    }
}
