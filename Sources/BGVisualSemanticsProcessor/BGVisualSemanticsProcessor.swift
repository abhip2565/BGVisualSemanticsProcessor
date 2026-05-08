import Foundation

/// The main entry point for the visual semantics library.
/// Coordinates storage, engine primitives, and the processing pipeline.
public final class BGVisualSemanticsProcessor: @unchecked Sendable {
    private let config: VisualSemanticsConfiguration
    private let pipeline: any VisualSemanticsPipeline
    private let jobStore: JobStore
    private let resultStore: ResultStore
    private let fileStore: ManagedFileStore
    private let batchProcessor: BatchProcessor
    private let broadcaster: ResultBroadcaster
    private let gate: ProcessingGate
    private let hasher: any SourceHashing
    private let logger: any VisualSemanticsLogger
    private let dateProvider: any DateProvider
    private let retryClassifier: any RetryClassifying
    private let drainScheduler: DrainScheduler

    public init(
        config: VisualSemanticsConfiguration,
        pipeline: VisualSemanticsPipeline,
        logger: VisualSemanticsLogger = OSLogVisualSemanticsLogger(),
        dateProvider: DateProvider = SystemDateProvider(),
        hasher: SourceHashing = SourceHasher(),
        retryClassifier: RetryClassifying = DefaultRetryClassifier()
    ) throws {
        self.config = config
        self.pipeline = pipeline
        self.logger = logger
        self.dateProvider = dateProvider
        self.hasher = hasher
        self.retryClassifier = retryClassifier

        let connection = try SQLiteConnection(location: config.databaseLocation)
        try MigrationRunner.migrate(connection: connection)

        self.jobStore = JobStore(connection: connection)
        self.resultStore = ResultStore(connection: connection)
        self.fileStore = try ManagedFileStore(directoryName: config.managedTempDirectoryName)
        self.batchProcessor = BatchProcessor()
        self.broadcaster = ResultBroadcaster()
        self.gate = ProcessingGate()
        self.drainScheduler = DrainScheduler()
        
        // Recover stale jobs on startup
        Task {
            let threshold = dateProvider.now().addingTimeInterval(-config.staleProcessingTimeout)
            let recovered = try? await jobStore.resetStaleJobs(threshold: threshold, now: dateProvider.now())
            if let recovered, recovered > 0 {
                self.logger.log(.staleJobsRecovered(count: recovered))
                self.scheduleDrain(mode: .foreground)
            }
        }
    }

    // MARK: - Enqueue

    public func enqueue(_ requests: [EnqueueRequest]) async throws -> EnqueueOutcome {
        logger.log(.enqueueRequested(itemIDs: requests.map { $0.itemID }))
        
        // Detect duplicates in the input batch
        let itemIDs = requests.map { $0.itemID }
        let duplicates = Dictionary(grouping: itemIDs, by: { $0 }).filter { $0.value.count > 1 }.map { $0.key }
        if !duplicates.isEmpty {
            throw VisualSemanticsError.duplicateItemIDsInBatch(itemIDs: duplicates)
        }

        var enqueued: [String] = []
        var coalesced: [String] = []
        var rejected: [(itemID: String, reason: VisualSemanticsError)] = []

        let now = dateProvider.now()

        // A4: Recover stale PROCESSING jobs before checking active state
        let staleThreshold = now.addingTimeInterval(-config.staleProcessingTimeout)
        let recoveredCount = try await jobStore.resetStaleJobs(threshold: staleThreshold, now: now)
        if recoveredCount > 0 {
            logger.log(.staleJobsRecovered(count: recoveredCount))
        }

        for request in requests {
            do {
                // Check if already active
                if let existing = try await jobStore.selectActive(itemID: request.itemID) {
                    if existing.status == .pending {
                        let didCoalesce = try await jobStore.coalescePending(itemID: request.itemID, priority: request.priority, now: now)
                        if didCoalesce {
                            coalesced.append(request.itemID)
                            continue
                        }
                    }
                    rejected.append((request.itemID, .itemBeingProcessed(itemID: request.itemID)))
                    continue
                }

                // Prepare source
                let persistedSource: PersistedImageSource
                var ownedPath: String? = nil

                switch request.source {
                case .fileURL(let path):
                    persistedSource = .fileURL(path)
                case .phAssetLocalIdentifier(let id):
                    persistedSource = .phAsset(id)
                case .data(let data, let ext):
                    let path = try await fileStore.writeData(data, suggestedExtension: ext)
                    persistedSource = .fileURL(path)
                    ownedPath = path
                }

                let job = VisualSemanticsJob(
                    jobID: UUID().uuidString,
                    itemID: request.itemID,
                    source: persistedSource,
                    priority: request.priority,
                    status: .pending,
                    attemptCount: 0,
                    nextAttemptAt: Date(timeIntervalSince1970: 0),
                    createdAt: now,
                    updatedAt: now,
                    lastError: nil,
                    ownedFilePath: ownedPath
                )

                try await jobStore.insert(job)
                enqueued.append(request.itemID)
            } catch {
                let vsError = (error as? VisualSemanticsError) ?? .storageFailure(reason: error.localizedDescription)
                rejected.append((request.itemID, vsError))
            }
        }

        let outcome = EnqueueOutcome(enqueued: enqueued, coalesced: coalesced, rejected: rejected)
        logger.log(.enqueueCompleted(outcome))

        // A1: Auto-drain — kick off processing without blocking the caller
        if !enqueued.isEmpty {
            scheduleDrain(mode: .foreground)
        }

        return outcome
    }

    // MARK: - Cancel

    public func cancel(itemIDs: [String]) async throws -> CancelOutcome {
        var cancelledPending: [String] = []
        var cancellingProcessing: [String] = []
        var alreadyTerminal: [String] = []
        var notFound: [String] = []

        let now = dateProvider.now()

        for itemID in itemIDs {
            if let job = try await jobStore.selectActive(itemID: itemID) {
                switch job.status {
                case .pending:
                    try await jobStore.transitionToCancelled(jobID: job.jobID, now: now)
                    
                    // Upsert cancelled result for pending items too so UI is updated
                    let cancelledResult = VisualSemanticsResult(
                        itemID: job.itemID,
                        jobID: job.jobID,
                        sourceHash: nil,
                        modelVersion: "unknown",
                        resultStatus: .cancelled,
                        imageType: nil,
                        labels: [],
                        quality: nil,
                        embedding: nil,
                        error: nil,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(config.resultTTL)
                    )
                    try await resultStore.upsert(cancelledResult, consumed: false, now: now)
                    
                    if let path = job.ownedFilePath { await fileStore.deleteFile(atPath: path) }
                    cancelledPending.append(itemID)
                case .processing:
                    await batchProcessor.cancel(jobID: job.jobID)
                    cancellingProcessing.append(itemID)
                default:
                    alreadyTerminal.append(itemID)
                }
            } else {
                notFound.append(itemID)
            }
        }

        return CancelOutcome(
            cancelledPending: cancelledPending,
            cancellingProcessing: cancellingProcessing,
            alreadyTerminal: alreadyTerminal,
            notFound: notFound
        )
    }

    public func cancelAllPending() async throws {
        let ids = try await jobStore.allPendingIDs()
        _ = try await cancel(itemIDs: ids)
    }

    // MARK: - Drain

    /// Schedules a drain to run in the background. Coalesces multiple calls.
    private func scheduleDrain(mode: ProcessingMode) {
        Task {
            let shouldStart = await drainScheduler.trySchedule()
            guard shouldStart else { return }

            do {
                try await self.drain(mode: mode)
            } catch {
                self.logger.log(.storageError(.pipelineFailure(reason: "auto-drain failed: \(error.localizedDescription)", isTransient: true)))
            }
            await drainScheduler.clear()
        }
    }

    @discardableResult
    public func drain(mode: ProcessingMode) async throws -> ProcessingSummary {
        // Enforce gate
        guard await gate.enter() else {
            logger.log(.drainGated(mode: mode))
            return ProcessingSummary(processed: 0, succeeded: 0, failedTransient: 0, failedPermanent: 0, cancelled: 0, skippedGated: true)
        }
        
        // Ensure we always leave the gate
        let summary: ProcessingSummary
        do {
            summary = try await performDrain(mode: mode)
        } catch {
            await gate.leave()
            throw error
        }
        
        await gate.leave()
        return summary
    }

    private func performDrain(mode: ProcessingMode) async throws -> ProcessingSummary {
        let batchSize = mode == .foreground ? config.foregroundBatchSize : config.backgroundBatchSize
        let concurrency = mode == .foreground ? config.foregroundConcurrency : 1
        logger.log(.drainStarted(mode: mode, batchSize: batchSize))

        let now = dateProvider.now()
        
        // Recover stale jobs first
        let threshold = now.addingTimeInterval(-config.staleProcessingTimeout)
        let recoveredCount = try await jobStore.resetStaleJobs(threshold: threshold, now: now)
        if recoveredCount > 0 {
            logger.log(.staleJobsRecovered(count: recoveredCount))
        }

        // Claim batch
        let jobs = try await jobStore.claimBatch(limit: batchSize, now: now)

        if jobs.isEmpty {
            let summary = ProcessingSummary(processed: 0, succeeded: 0, failedTransient: 0, failedPermanent: 0, cancelled: 0, skippedGated: false)
            logger.log(.drainCompleted(mode: mode, summary))
            return summary
        }

        print("[VSLib] drain claiming \(jobs.count) jobs (concurrency=\(concurrency)): \(jobs.map { String($0.itemID.prefix(8)) }.joined(separator: ", "))")

        // A6: Drain-level timeout as safety net
        let drainTimeout = config.perJobTimeout * Double(jobs.count + 1)

        let finalSummary: ProcessingSummary = await {
            // Race the real drain work against a timeout
            let drainTask = Task { [self] in
                try await self.processJobsConcurrently(jobs, concurrency: concurrency, mode: mode)
            }
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(drainTimeout * 1_000_000_000))
            }

            let summary: ProcessingSummary
            do {
                // Wait for drain to finish
                summary = try await drainTask.value
                timeoutTask.cancel()
            } catch {
                // Drain threw (or was cancelled by timeout) — cancel everything
                drainTask.cancel()
                timeoutTask.cancel()
                await batchProcessor.cancelAll()
                print("[VSLib] drain failed/timeout — cancelled remaining jobs: \(error.localizedDescription)")
                summary = ProcessingSummary(
                    processed: jobs.count,
                    succeeded: 0,
                    failedTransient: 0,
                    failedPermanent: jobs.count,
                    cancelled: 0,
                    skippedGated: false
                )
            }

            // Also cancel drain if timeout fires first
            Task { [self] in
                do {
                    try await timeoutTask.value
                    // Timeout completed before drain — cancel drain
                    drainTask.cancel()
                    await self.batchProcessor.cancelAll()
                    print("[VSLib] drain timeout after \(Int(drainTimeout))s — cancelling")
                } catch {
                    // Timeout was cancelled (drain finished first) — nothing to do
                }
            }

            return summary
        }()

        logger.log(.drainCompleted(mode: mode, finalSummary))
        return finalSummary
    }

    // A3: Concurrency-limited parallel processing
    private func processJobsConcurrently(_ jobs: [VisualSemanticsJob], concurrency: Int, mode: ProcessingMode) async throws -> ProcessingSummary {
        var succeeded = 0
        var failedPermanent = 0
        var cancelled = 0

        await withTaskGroup(of: ResultStatus.self) { group in
            var jobIterator = jobs.makeIterator()
            var active = 0

            // Seed up to concurrency limit
            while active < concurrency, let job = jobIterator.next() {
                group.addTask { await self.processJobSafe(job, mode: mode) }
                active += 1
            }

            // As each completes, launch the next
            for await status in group {
                switch status {
                case .completed: succeeded += 1
                case .failed: failedPermanent += 1
                case .cancelled: cancelled += 1
                }
                active -= 1

                if let job = jobIterator.next() {
                    group.addTask { await self.processJobSafe(job, mode: mode) }
                    active += 1
                }
            }
        }

        return ProcessingSummary(
            processed: jobs.count,
            succeeded: succeeded,
            failedTransient: 0,
            failedPermanent: failedPermanent,
            cancelled: cancelled,
            skippedGated: false
        )
    }

    // A5: Error-isolated wrapper — never throws, always returns a status
    private func processJobSafe(_ job: VisualSemanticsJob, mode: ProcessingMode) async -> ResultStatus {
        do {
            return try await processJobWithTimeout(job, mode: mode)
        } catch {
            // Last-resort catch: mark job failed so it doesn't stay PROCESSING
            print("[VSLib] processJobSafe unexpected error for \(String(job.itemID.prefix(8))): \(error)")
            let now = dateProvider.now()
            let persistedError = PersistedJobError(
                code: "UNEXPECTED_ERROR",
                message: error.localizedDescription,
                isTransient: true
            )
            try? await jobStore.transitionToFailed(jobID: job.jobID, error: persistedError, now: now)
            let failureResult = VisualSemanticsResult(
                itemID: job.itemID,
                jobID: job.jobID,
                sourceHash: nil,
                modelVersion: "unknown",
                resultStatus: .failed,
                imageType: nil,
                labels: [],
                quality: nil,
                embedding: nil,
                error: ResultError(code: persistedError.code, message: persistedError.message),
                createdAt: now,
                expiresAt: now.addingTimeInterval(config.resultTTL)
            )
            try? await resultStore.upsert(failureResult, consumed: false, now: now)
            await broadcaster.broadcast(failureResult)
            logger.log(.jobFailed(jobID: job.jobID, itemID: job.itemID, error: .pipelineFailure(reason: error.localizedDescription, isTransient: true), willRetry: false))
            return .failed
        }
    }

    // A2: Per-job timeout enforcement
    private func processJobWithTimeout(_ job: VisualSemanticsJob, mode: ProcessingMode) async throws -> ResultStatus {
        let timeout = config.perJobTimeout

        return try await withThrowingTaskGroup(of: ResultStatus.self) { group in
            // Real work
            group.addTask {
                return try await self.processJob(job, mode: mode)
            }

            // Timeout watchdog
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw VisualSemanticsError.pipelineFailure(reason: "job timeout after \(Int(timeout))s", isTransient: true)
            }

            // Whichever finishes first wins
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func processJob(_ job: VisualSemanticsJob, mode: ProcessingMode) async throws -> ResultStatus {
        let jobTask = Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            logger.log(.jobStarted(jobID: job.jobID, itemID: job.itemID, attempt: job.attemptCount))
            
            do {
                let context = PipelineContext(
                    jobID: job.jobID,
                    itemID: job.itemID,
                    source: try mapSource(job.source),
                    modeHint: mode
                )

                print("[VSLib] pipeline start: \(String(job.itemID.prefix(8))) source=\(context.source)")
                let t0 = CFAbsoluteTimeGetCurrent()
                let output = try await pipeline.process(context)
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                print("[VSLib] pipeline done: \(String(job.itemID.prefix(8))) in \(Int(elapsed))ms labels=\(output.labels.count) type=\(output.imageType?.rawValue ?? "nil")")
                let now = dateProvider.now()
                
                let result = VisualSemanticsResult(
                    itemID: job.itemID,
                    jobID: job.jobID,
                    sourceHash: output.sourceHash,
                    modelVersion: output.modelVersion,
                    resultStatus: .completed,
                    imageType: output.imageType,
                    labels: output.labels,
                    quality: output.quality,
                    embedding: output.embedding,
                    error: nil,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(config.resultTTL)
                )

                try await resultStore.upsert(result, consumed: false, now: now)
                try await jobStore.transitionToCompleted(jobID: job.jobID, now: now)
                if let path = job.ownedFilePath { await fileStore.deleteFile(atPath: path) }
                
                await broadcaster.broadcast(result)
                
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                logger.log(.jobCompleted(jobID: job.jobID, itemID: job.itemID, durationSec: duration))
                return ResultStatus.completed

            } catch is CancellationError {
                let now = dateProvider.now()
                try await jobStore.transitionToCancelled(jobID: job.jobID, now: now)
                
                // Upsert cancelled result
                let cancelledResult = VisualSemanticsResult(
                    itemID: job.itemID,
                    jobID: job.jobID,
                    sourceHash: nil,
                    modelVersion: "unknown",
                    resultStatus: .cancelled,
                    imageType: nil,
                    labels: [],
                    quality: nil,
                    embedding: nil,
                    error: nil,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(config.resultTTL)
                )
                try await resultStore.upsert(cancelledResult, consumed: false, now: now)
                if let path = job.ownedFilePath { await fileStore.deleteFile(atPath: path) }
                
                await broadcaster.broadcast(cancelledResult)
                logger.log(.jobCancelled(jobID: job.jobID, itemID: job.itemID, reason: .userRequested))
                return ResultStatus.cancelled
                
            } catch {
                let now = dateProvider.now()
                let isTransient = retryClassifier.isTransient(error)
                let vsError = (error as? VisualSemanticsError) ?? .pipelineFailure(reason: error.localizedDescription, isTransient: isTransient)
                
                let persistedError = PersistedJobError(
                    code: String(describing: vsError),
                    message: error.localizedDescription,
                    isTransient: isTransient
                )

                if isTransient && job.attemptCount < config.maxAttempts {
                    let delay = calculateRetryDelay(attempt: job.attemptCount)
                    let nextAttempt = now.addingTimeInterval(delay)
                    try await jobStore.transitionToPending(jobID: job.jobID, error: persistedError, nextAttemptAt: nextAttempt, now: now)
                    logger.log(.jobFailed(jobID: job.jobID, itemID: job.itemID, error: vsError, willRetry: true))
                    return ResultStatus.failed // Still "failed" this run
                } else {
                    try await jobStore.transitionToFailed(jobID: job.jobID, error: persistedError, now: now)
                    
                    // Upsert failure result
                    let failureResult = VisualSemanticsResult(
                        itemID: job.itemID,
                        jobID: job.jobID,
                        sourceHash: nil,
                        modelVersion: "unknown",
                        resultStatus: .failed,
                        imageType: nil,
                        labels: [],
                        quality: nil,
                        embedding: nil,
                        error: ResultError(code: persistedError.code, message: persistedError.message),
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(config.resultTTL)
                    )
                    try await resultStore.upsert(failureResult, consumed: false, now: now)
                    if let path = job.ownedFilePath { await fileStore.deleteFile(atPath: path) }
                    
                    await broadcaster.broadcast(failureResult)
                    logger.log(.jobFailed(jobID: job.jobID, itemID: job.itemID, error: vsError, willRetry: false))
                    return ResultStatus.failed
                }
            }
        }

        await batchProcessor.register(jobID: job.jobID, canceller: { jobTask.cancel() })
        let status = try await jobTask.value
        await batchProcessor.unregister(jobID: job.jobID)
        return status
    }

    // MARK: - Results

    public func result(for itemID: String) async throws -> VisualSemanticsResult? {
        return try await resultStore.result(forItemID: itemID)
    }

    public func results(for itemIDs: [String]) async throws -> [String: VisualSemanticsResult] {
        var results: [String: VisualSemanticsResult] = [:]
        for id in itemIDs {
            if let r = try await resultStore.result(forItemID: id) {
                results[id] = r
            }
        }
        return results
    }

    public func markConsumed(itemIDs: [String]) async throws {
        try await resultStore.markConsumed(itemIDs: itemIDs, now: dateProvider.now())
    }

    public func makeResultStream() async -> AsyncStream<VisualSemanticsResult> {
        return await broadcaster.subscribe()
    }

    public func pendingResults(limit: Int = 100) async throws -> [VisualSemanticsResult] {
        return try await resultStore.pendingResults(limit: limit)
    }

    // MARK: - Lifecycle

    public func applicationDidBecomeActive() async {
        // In v1, this triggers a maintenance drain
        try? await drain(mode: .foreground)
    }

    public func applicationDidEnterBackground() async {
        // In v1, we ensure any active foreground work is cleanly stopped if possible
        // but primarily this is a hook for future pre-warming or scheduling.
    }

    // MARK: - Maintenance

    public func purge() async throws {
        let now = dateProvider.now()
        let purgedResults = try await resultStore.purgeExpired(now: now, purgeUnconsumed: config.purgeUnconsumedExpiredResults)
        
        // Prune jobs older than 7 days
        let threshold = now.addingTimeInterval(-7 * 24 * 3600)
        let prunedJobs = try await resultStore.pruneTerminalJobsOlderThan(threshold)
        
        // Orphaned files sweep
        // This is expensive, so we only do it during explicit purge
        // In a real impl, we'd query jobStore for all active ownedFilePath
        // For v1, we skip the full cross-reference sweep here for performance unless requested.
    }

    // MARK: - Helpers

    private func mapSource(_ source: PersistedImageSource) throws -> ImageSourceReference {
        switch source {
        case .fileURL(let path): return .fileURL(path: path)
        case .phAsset(let id): return .phAssetLocalIdentifier(id)
        }
    }

    // MARK: - Diagnostics (Testing Only)
    
    private func calculateRetryDelay(attempt: Int) -> TimeInterval {
        let base = config.retry.baseDelay * pow(2.0, Double(attempt - 1))
        let jitter = base * config.retry.jitterFraction * (Double.random(in: -1.0...1.0))
        return min(config.retry.maxDelay, base + jitter)
    }

    // MARK: - Diagnostics (Testing Only)
    
    internal func diagnosticPendingCount() async throws -> Int {
        return try await jobStore.pendingCount()
    }
}
