import Foundation

/// Request to enqueue an item for processing.
public struct EnqueueRequest: Sendable {
    public let itemID: String
    public let source: ImageSourceReference
    public let priority: JobPriority

    public init(itemID: String, source: ImageSourceReference, priority: JobPriority = .normal) {
        self.itemID = itemID
        self.source = source
        self.priority = priority
    }
}
