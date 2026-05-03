import Foundation

/// Reference to an image source.
public enum ImageSourceReference: Sendable, Hashable {
    case fileURL(path: String)
    case phAssetLocalIdentifier(String)
    case data(Data, suggestedExtension: String)
}

extension ImageSourceReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case identifier
        case data
        case suggestedExtension
    }

    private enum Kind: String, Codable {
        case fileURL
        case phAssetLocalIdentifier
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .kind)
        
        // Match kind string or fallback for forwards compatibility
        switch kindString {
        case Kind.fileURL.rawValue:
            let path = try container.decode(String.self, forKey: .path)
            self = .fileURL(path: path)
        case Kind.phAssetLocalIdentifier.rawValue:
            let identifier = try container.decode(String.self, forKey: .identifier)
            self = .phAssetLocalIdentifier(identifier)
        case Kind.data.rawValue:
            let data = try container.decode(Data.self, forKey: .data)
            let ext = try container.decode(String.self, forKey: .suggestedExtension)
            self = .data(data, suggestedExtension: ext)
        default:
            // Forwards compatibility: if we encounter an unknown kind, we throw a dataCorrupted error
            // which can be caught by the caller to handle gracefully.
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown ImageSourceReference kind: \(kindString)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fileURL(let path):
            try container.encode(Kind.fileURL.rawValue, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .phAssetLocalIdentifier(let identifier):
            try container.encode(Kind.phAssetLocalIdentifier.rawValue, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        case .data(let data, let ext):
            try container.encode(Kind.data.rawValue, forKey: .kind)
            try container.encode(data, forKey: .data)
            try container.encode(ext, forKey: .suggestedExtension)
        }
    }
}
