import Foundation

/// Internal representation of a visual processing job.
struct VisualSemanticsJob: Sendable, Equatable {
    let jobID: String
    let itemID: String
    let source: PersistedImageSource
    let priority: JobPriority
    var status: JobStatus
    var attemptCount: Int
    var nextAttemptAt: Date
    let createdAt: Date
    var updatedAt: Date
    var lastError: PersistedJobError?
    let ownedFilePath: String?
}

enum PersistedImageSource: Sendable, Equatable {
    case fileURL(String)
    case phAsset(String)
}

enum JobStatus: String, Sendable, Equatable {
    case pending, processing, completed, failed, cancelled
}

struct PersistedJobError: Sendable, Equatable {
    let code: String
    let message: String
    let isTransient: Bool
}
