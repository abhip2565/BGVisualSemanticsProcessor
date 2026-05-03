import Foundation

/// Tracks in-flight processing tasks and allows for targeted cancellation.
actor BatchProcessor {
    private var inFlightTasks: [String: @Sendable () -> Void] = [:]
    
    /// Registers a cancellation block for a given job ID.
    func register(jobID: String, canceller: @escaping @Sendable () -> Void) {
        inFlightTasks[jobID] = canceller
    }
    
    /// Unregisters a canceller when it completes or fails.
    func unregister(jobID: String) {
        inFlightTasks.removeValue(forKey: jobID)
    }
    
    /// Cancels the task associated with the given job ID.
    func cancel(jobID: String) {
        if let canceller = inFlightTasks[jobID] {
            canceller()
            inFlightTasks.removeValue(forKey: jobID)
        }
    }
    
    /// Cancels all currently tracked tasks.
    func cancelAll() {
        for canceller in inFlightTasks.values {
            canceller()
        }
        inFlightTasks.removeAll()
    }
}
