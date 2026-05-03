import Foundation

/// Logger for visual semantics events.
public protocol VisualSemanticsLogger: Sendable {
    func log(_ event: VisualSemanticsLogEvent)
}

/// Events logged by the processor.
public enum VisualSemanticsLogEvent: Sendable {
    case enqueueRequested(itemIDs: [String])
    case enqueueCompleted(EnqueueOutcome)
    case drainStarted(mode: ProcessingMode, batchSize: Int)
    case drainCompleted(mode: ProcessingMode, ProcessingSummary)
    case drainGated(mode: ProcessingMode)
    case jobStarted(jobID: String, itemID: String, attempt: Int)
    case jobCompleted(jobID: String, itemID: String, durationSec: Double)
    case jobFailed(jobID: String, itemID: String, error: VisualSemanticsError, willRetry: Bool)
    case jobCancelled(jobID: String, itemID: String, reason: CancelReason)
    case staleJobsRecovered(count: Int)
    case bgTaskScheduled
    case bgTaskRunning
    case bgTaskExpired
    case migrationApplied(from: Int, to: Int)
    case storageError(VisualSemanticsError)
}

/// Reason for cancellation.
public enum CancelReason: Sendable {
    case userRequested
    case batchCancelled
    case backgroundExpired
}

import OSLog

/// Default logger implementation using OSLog.
@available(iOS 15.0, *)
public struct OSLogVisualSemanticsLogger: VisualSemanticsLogger {
    private let logger = Logger(subsystem: "com.bgvisualsemantics", category: "processor")

    public init() {}

    public func log(_ event: VisualSemanticsLogEvent) {
        // Implementation for v1: just log the event kind for now.
        // Full implementation with detailed formatting can be added later.
        logger.debug("Event: \(String(describing: event), privacy: .public)")
    }
}
