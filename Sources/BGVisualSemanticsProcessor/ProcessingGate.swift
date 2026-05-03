import Foundation

/// A concurrency primitive that ensures only one operation proceeds at a time.
/// Used to prevent concurrent background and foreground drains.
actor ProcessingGate {
    private var isProcessing = false
    
    /// Attempts to enter the gate.
    /// - Returns: `true` if entered successfully, `false` if already processing.
    func enter() -> Bool {
        if isProcessing {
            return false
        }
        isProcessing = true
        return true
    }
    
    /// Leaves the gate, allowing subsequent operations to enter.
    func leave() {
        isProcessing = false
    }
}
