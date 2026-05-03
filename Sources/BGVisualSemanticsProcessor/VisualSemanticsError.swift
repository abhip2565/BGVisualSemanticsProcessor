import Foundation

/// Errors thrown by the visual semantics processor.
public enum VisualSemanticsError: Error, Sendable, Equatable {
    case imageNotFound(reason: String)
    case imageDecodeFailed(reason: String)
    case unsupportedImageSource(reason: String)
    case processingCancelled
    case modelUnavailable(name: String)
    case storageFailure(reason: String)
    case pipelineFailure(reason: String, isTransient: Bool)
    case duplicateItemIDsInBatch(itemIDs: [String])
    case itemBeingProcessed(itemID: String)
    case configurationInvalid(reason: String)
    case databaseSchemaIncompatible(have: Int, expected: Int)
}
