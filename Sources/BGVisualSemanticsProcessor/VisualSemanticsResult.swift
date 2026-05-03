import Foundation

/// Result of visual semantics processing.
public struct VisualSemanticsResult: Codable, Sendable, Equatable {
    public let itemID: String
    public let jobID: String
    public let sourceHash: String?
    public let modelVersion: String
    public let resultStatus: ResultStatus
    public let imageType: VisualImageType?
    public let labels: [VisualLabel]
    public let quality: ImageQuality?
    public let embedding: VisualEmbedding?
    public let error: ResultError?
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        itemID: String,
        jobID: String,
        sourceHash: String?,
        modelVersion: String,
        resultStatus: ResultStatus,
        imageType: VisualImageType?,
        labels: [VisualLabel],
        quality: ImageQuality?,
        embedding: VisualEmbedding?,
        error: ResultError?,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.itemID = itemID
        self.jobID = jobID
        self.sourceHash = sourceHash
        self.modelVersion = modelVersion
        self.resultStatus = resultStatus
        self.imageType = imageType
        self.labels = labels
        self.quality = quality
        self.embedding = embedding
        self.error = error
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// Status of a processing result.
public enum ResultStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

/// Error details in a result.
public struct ResultError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A visual label produced by the pipeline.
public struct VisualLabel: Codable, Sendable, Equatable {
    public let name: String
    public let confidence: Double
    public let source: VisualLabelSource

    public init(name: String, confidence: Double, source: VisualLabelSource) {
        self.name = name
        self.confidence = confidence
        self.source = source
    }
}

/// Source of a visual label.
public enum VisualLabelSource: Sendable, Equatable {
    case vision(version: String)
    case coreML(modelID: String)
    case heuristic(name: String)
}

extension VisualLabelSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case modelID
        case name
    }

    private enum Kind: String, Codable {
        case vision
        case coreML
        case heuristic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindString = try container.decode(String.self, forKey: .kind)

        switch kindString {
        case Kind.vision.rawValue:
            let version = try container.decode(String.self, forKey: .version)
            self = .vision(version: version)
        case Kind.coreML.rawValue:
            let modelID = try container.decode(String.self, forKey: .modelID)
            self = .coreML(modelID: modelID)
        case Kind.heuristic.rawValue:
            let name = try container.decode(String.self, forKey: .name)
            self = .heuristic(name: name)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown VisualLabelSource kind: \(kindString)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .vision(let version):
            try container.encode(Kind.vision.rawValue, forKey: .kind)
            try container.encode(version, forKey: .version)
        case .coreML(let modelID):
            try container.encode(Kind.coreML.rawValue, forKey: .kind)
            try container.encode(modelID, forKey: .modelID)
        case .heuristic(let name):
            try container.encode(Kind.heuristic.rawValue, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Structural taxonomy of image types based on how the image was produced.
public enum VisualImageType: String, Codable, Sendable {
    case photo
    case screenshot
    case document
    case graphic
    case unknown
}

/// Visual quality metrics.
public struct ImageQuality: Codable, Sendable, Equatable {
    public let sharpness: Double?
    public let brightness: Double?

    public init(sharpness: Double?, brightness: Double?) {
        self.sharpness = sharpness
        self.brightness = brightness
    }
}

/// Visual embedding vector.
public struct VisualEmbedding: Codable, Sendable, Equatable {
    public let modelID: String
    public let dimensions: Int
    public let vector: [Float]

    public init(modelID: String, dimensions: Int, vector: [Float]) {
        self.modelID = modelID
        self.dimensions = dimensions
        self.vector = vector
    }
}
