import Foundation

/// Actor that prevents duplicate drain scheduling.
/// Only one drain runs at a time; subsequent requests are coalesced.
actor DrainScheduler {
    private var isScheduled = false

    /// Attempts to schedule a drain. Returns true if this caller should run it.
    func trySchedule() -> Bool {
        if isScheduled { return false }
        isScheduled = true
        return true
    }

    /// Marks the current drain as finished, allowing future scheduling.
    func clear() {
        isScheduled = false
    }
}
