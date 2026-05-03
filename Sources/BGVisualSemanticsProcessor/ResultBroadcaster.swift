import Foundation

/// Broadcasts processing results to multiple subscribers.
/// Uses an actor to ensure thread-safe access to continuations across iOS 15+.
actor ResultBroadcaster {
    private var continuations: [UUID: AsyncStream<VisualSemanticsResult>.Continuation] = [:]
    
    /// Subscribes to the result stream.
    func subscribe(
        bufferingPolicy: AsyncStream<VisualSemanticsResult>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<VisualSemanticsResult> {
        let id = UUID()
        return AsyncStream(VisualSemanticsResult.self, bufferingPolicy: bufferingPolicy) { continuation in
            // We must insert the continuation into the actor's state.
            // Because the builder closure is synchronous, we spin up a task to call the actor.
            Task {
                await self.addContinuation(id: id, continuation: continuation)
            }
            
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }
    
    private func addContinuation(id: UUID, continuation: AsyncStream<VisualSemanticsResult>.Continuation) {
        continuations[id] = continuation
    }
    
    /// Broadcasts a result to all active subscribers.
    func broadcast(_ result: VisualSemanticsResult) {
        for continuation in continuations.values {
            continuation.yield(result)
        }
    }
    
    /// Removes a continuation by its identifier.
    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
    
    /// Diagnostic count of active subscribers.
    var subscriberCount: Int {
        continuations.count
    }
}
