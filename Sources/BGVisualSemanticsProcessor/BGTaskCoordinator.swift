#if canImport(BackgroundTasks)
import Foundation
@preconcurrency import BackgroundTasks

/// Thread-safe storage for deferred processor binding.
/// BGTaskScheduler requires handler registration before app finishes launching,
/// but the processor is created later. This bridges the two.
private final class ProcessorRegistry: @unchecked Sendable {
    private var storage: [String: BGVisualSemanticsProcessor] = [:]
    private let lock = NSLock()

    func set(_ processor: BGVisualSemanticsProcessor, for identifier: String) {
        lock.withLock { storage[identifier] = processor }
    }

    func get(_ identifier: String) -> BGVisualSemanticsProcessor? {
        lock.withLock { storage[identifier] }
    }
}

private let sharedRegistry = ProcessorRegistry()

/// Coordinates background processing using Apple's BackgroundTasks framework.
public actor BGTaskCoordinator {
    private let processor: BGVisualSemanticsProcessor
    private let identifier: String
    private let logger: any VisualSemanticsLogger

    public init(
        identifier: String,
        processor: BGVisualSemanticsProcessor,
        logger: any VisualSemanticsLogger = OSLogVisualSemanticsLogger()
    ) {
        self.processor = processor
        self.identifier = identifier
        self.logger = logger
    }

    /// Registers the background task handler with the system.
    /// Call this synchronously during App.init() or
    /// application(_:didFinishLaunchingWithOptions:), before the app finishes launching.
    /// Bind the processor later by creating a ``BGTaskCoordinator`` and calling ``register()``.
    @MainActor
    public static func registerHandler(identifier: String) {
        let success = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task {
                await handleRegisteredTask(task, identifier: identifier)
            }
        }

        if !success {
            print("[BGTaskCoordinator] Failed to register background task identifier \(identifier). Ensure it is in Info.plist BGTaskSchedulerPermittedIdentifiers.")
        }
    }

    private static func handleRegisteredTask(_ task: BGTask, identifier: String) async {
        guard let processor = sharedRegistry.get(identifier) else {
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { }

        do {
            let summary = try await processor.drain(mode: .background)
            if summary.processed > 0 {
                let request = BGProcessingTaskRequest(identifier: identifier)
                request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
                request.requiresNetworkConnectivity = false
                request.requiresExternalPower = true
                try? BGTaskScheduler.shared.submit(request)
            }
            task.setTaskCompleted(success: true)
        } catch {
            task.setTaskCompleted(success: false)
        }
    }

    /// Binds this coordinator's processor so background task launches can use it.
    /// Call after creating the coordinator (once the processor is ready).
    @MainActor
    public func register() {
        sharedRegistry.set(processor, for: identifier)
    }

    /// Schedules a background processing task to run in the future.
    public func scheduleProcessing(earliestBeginDate: Date? = nil) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.log(.bgTaskScheduled)
        } catch {
            logger.log(.storageError(.storageFailure(reason: "Failed to submit background task: \(error.localizedDescription)")))
        }
    }

    /// Manually handles a task (can be called by system or for testing).
    public func handleTask(_ task: BGTask) async {
        logger.log(.bgTaskRunning)

        task.expirationHandler = {
            Task {
                await self.handleExpiration()
            }
        }

        do {
            let summary = try await processor.drain(mode: .background)

            if summary.processed > 0 {
                scheduleProcessing(earliestBeginDate: Date(timeIntervalSinceNow: 15 * 60))
            }

            task.setTaskCompleted(success: true)
        } catch {
            logger.log(.storageError(.pipelineFailure(reason: "Background task drain failed: \(error.localizedDescription)", isTransient: true)))
            task.setTaskCompleted(success: false)
        }
    }

    private func handleExpiration() async {
        logger.log(.bgTaskExpired)
    }
}
#endif
