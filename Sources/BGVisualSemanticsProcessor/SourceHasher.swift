import Foundation

/// Protocol for generating stable hashes of image sources.
public protocol SourceHashing: Sendable {
    func hash(for source: ImageSourceReference) -> String?
}

/// Default implementation for hashing sources based on metadata.
public struct SourceHasher: SourceHashing {
    public init() {}
    
    public func hash(for source: ImageSourceReference) -> String? {
        switch source {
        case .fileURL(let path):
            let url = URL(fileURLWithPath: path)
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .documentIdentifierKey]) else {
                return nil
            }
            
            // Construct a hash string based on inode (documentIdentifier), mtime, and size
            let inode = attrs.documentIdentifier ?? 0
            let mtime = attrs.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = attrs.fileSize ?? 0
            
            return "\(inode)-\(mtime)-\(size)"
            
        case .phAssetLocalIdentifier(let identifier):
            // In a full implementation, we might query Photos for modificationDate here.
            // For the hashing protocol standalone, returning the identifier is the best deterministic proxy
            // without bringing in Photos framework directly to this core logic.
            // We will augment this in the Vision loader.
            return identifier
            
        case .data(let data, _):
            // SHA256 or similar would be better, but basic count is a fast naive hash
            return "data-size-\(data.count)"
        }
    }
}
