import Foundation

/// Protocol for classifying errors as transient or permanent.
public protocol RetryClassifying: Sendable {
    func isTransient(_ error: Error) -> Bool
}

/// Default implementation of retry classifier.
public struct DefaultRetryClassifier: RetryClassifying {
    public init() {}
    public func isTransient(_ error: Error) -> Bool {
        if let e = error as? VisualSemanticsError {
            switch e {
            case .imageNotFound, .imageDecodeFailed, .unsupportedImageSource:
                return false
            case .processingCancelled, .duplicateItemIDsInBatch,
                 .itemBeingProcessed, .configurationInvalid,
                 .databaseSchemaIncompatible:
                return false
            case .modelUnavailable, .storageFailure:
                return true
            case .pipelineFailure(_, let isTransient):
                return isTransient
            }
        }
        return true
    }
}
