import Foundation

/// Broadcasts processing results to multiple subscribers.
/// Uses an actor to ensure thread-safe access to continuations across iOS 15+.
actor ResultBroadcaster {
    private var continuations: [UUID: AsyncStream<VisualSemanticsResult>.Continuation] = [:]

    /// Subscribes to the result stream.
    /// The continuation is registered synchronously before returning, eliminating
    /// the race window where early broadcasts could be lost.
    func subscribe(
        bufferingPolicy: AsyncStream<VisualSemanticsResult>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<VisualSemanticsResult> {
        let id = UUID()
        // Capture the continuation synchronously via a wrapper so we can register
        // it inside this actor-isolated method before any broadcast can interleave.
        var captured: AsyncStream<VisualSemanticsResult>.Continuation!
        let stream = AsyncStream(VisualSemanticsResult.self, bufferingPolicy: bufferingPolicy) { continuation in
            captured = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
        // Register immediately — we are already inside the actor, so no race.
        continuations[id] = captured
        return stream
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
