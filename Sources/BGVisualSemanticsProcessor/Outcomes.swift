import Foundation

/// Outcome of an enqueue operation.
public struct EnqueueOutcome: Sendable, Equatable {
    public let enqueued: [String]
    public let coalesced: [String]
    public let rejected: [(itemID: String, reason: VisualSemanticsError)]

    public init(
        enqueued: [String],
        coalesced: [String],
        rejected: [(itemID: String, reason: VisualSemanticsError)]
    ) {
        self.enqueued = enqueued
        self.coalesced = coalesced
        self.rejected = rejected
    }

    public static func == (lhs: EnqueueOutcome, rhs: EnqueueOutcome) -> Bool {
        lhs.enqueued == rhs.enqueued &&
        lhs.coalesced == rhs.coalesced &&
        lhs.rejected.map { $0.itemID } == rhs.rejected.map { $0.itemID } &&
        lhs.rejected.map { $0.reason } == rhs.rejected.map { $0.reason }
    }
}

/// Outcome of a cancel operation.
public struct CancelOutcome: Sendable, Equatable {
    public let cancelledPending: [String]
    public let cancellingProcessing: [String]
    public let alreadyTerminal: [String]
    public let notFound: [String]

    public init(
        cancelledPending: [String],
        cancellingProcessing: [String],
        alreadyTerminal: [String],
        notFound: [String]
    ) {
        self.cancelledPending = cancelledPending
        self.cancellingProcessing = cancellingProcessing
        self.alreadyTerminal = alreadyTerminal
        self.notFound = notFound
    }
}

/// Summary of a processing drain.
public struct ProcessingSummary: Sendable, Equatable {
    public let processed: Int
    public let succeeded: Int
    public let failedTransient: Int
    public let failedPermanent: Int
    public let cancelled: Int
    public let skippedGated: Bool

    public init(
        processed: Int,
        succeeded: Int,
        failedTransient: Int,
        failedPermanent: Int,
        cancelled: Int,
        skippedGated: Bool
    ) {
        self.processed = processed
        self.succeeded = succeeded
        self.failedTransient = failedTransient
        self.failedPermanent = failedPermanent
        self.cancelled = cancelled
        self.skippedGated = skippedGated
    }
}

/// Mode for processing jobs.
public enum ProcessingMode: Sendable {
    case foreground
    case background
}
