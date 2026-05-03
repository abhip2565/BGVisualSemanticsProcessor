# Implementation Prompt — BGVisualSemanticsProcessor v1

You are implementing a production-grade Swift library end-to-end. The complete design specification is in `BGVisualSemanticsProcessor-design.md` in this repository. **Read the entire design document before writing a single line of code.** It is 8,600+ words long, has 25 sections, a 50-row edge case matrix, and 8 sequence diagrams. Every public type signature, error case, SQL schema, state transition, and concurrency primitive in the doc is a hard requirement, not a suggestion.

This prompt does not duplicate the spec. It defines: the quality bar, the phased build order, the test requirements, the code style rules, and how you should report progress.

---

## Hard constraints (non-negotiable)

1. **Swift 6 strict concurrency.** Set `swiftLanguageMode: .v6` in `Package.swift`. Every public type must be `Sendable`. No `@unchecked Sendable` unless you justify it in a commit message and there is no alternative. Use actors, value types, or `OSAllocatedUnfairLock` (from `os`) for synchronisation.

2. **iOS 15+.** Set `platforms: [.iOS(.v15)]`. Use `BGProcessingTask` (iOS 13+) and `Vision`'s revisioned APIs.

3. **Zero external dependencies.** No SwiftPM packages beyond the Swift toolchain and Apple frameworks. SQLite via `import SQLite3` (the system C module). If you think you need a dependency, stop and ask.

4. **Public API matches the design doc exactly.** Method names, parameter labels, return types, error cases, default values — all verbatim. If the doc is wrong or contradictory, flag it; do not silently change the API.

5. **No inline comments in Swift code.** Use `///` DocC for public API documentation. Inside method bodies, no `//` comments. The code must read clearly without them; if it doesn't, the code needs to change, not get a comment. (This is a non-negotiable preference of the project owner.)

6. **No force unwraps (`!`) in production code** except for compiler-proven invariants (e.g., string literal regex). Tests may use force unwraps where appropriate.

7. **All library APIs are async** unless they are pure value-type constructors or trivial accessors on `let` properties. If a method touches storage, the broadcaster, or the gate, it is `async`.

8. **No singletons.** Every dependency is injected through the initializer. The library never reads from `UserDefaults`, never observes `UIApplication` notifications internally (host calls `applicationDidBecomeActive`/`applicationDidEnterBackground` explicitly per the spec), never reaches for `FileManager.default` outside the `ManagedFileStore`.

---

## Phased build order

You will implement in nine phases. After each phase: run all tests, summarise what was built and what tests pass, and **wait for explicit confirmation before starting the next phase**. Do not proceed on your own. Do not batch phases together to save round trips.

Within a phase, commit logical sub-units. Each commit message follows the form:
`phase-N: <module>: <what changed>` — e.g., `phase-2: JobStore: dequeue with priority + backoff`.

### Phase 1 — Package skeleton and models

- `Package.swift` with two products (`BGVisualSemanticsProcessor`, `BGVisualSemanticsProcessorVision`), platforms, Swift 6 mode.
- All public model types from §4 of the spec: `ImageSourceReference`, `EnqueueRequest`, `JobPriority`, `VisualSemanticsResult`, `ResultStatus`, `ResultError`, `VisualLabel`, `VisualLabelSource`, `VisualImageType`, `ImageQuality`, `VisualEmbedding`, `VisualSemanticsError`.
- Custom `Codable` for `ImageSourceReference` and `VisualLabelSource` with discriminator field — not synthesised. Backwards compatibility test required.
- `VisualSemanticsConfiguration`, `DatabaseLocation`, `RetryPolicy`, `ProcessingMode`, all outcome types (`EnqueueOutcome`, `CancelOutcome`, `ProcessingSummary`).
- `DateProvider` protocol + `SystemDateProvider`. `VisualSemanticsLogger` protocol + `OSLogVisualSemanticsLogger`.
- `RetryClassifying` protocol + `DefaultRetryClassifier` per §20.

**Tests for phase 1:**
- Configuration validation rejects invalid values per §3 (`foregroundBatchSize < 1`, `maxAttempts < 1`, etc.) — one test per invariant.
- `Codable` round-trip for every public type, including the discriminator-based types.
- `Codable` *forwards-compat* test: encode with a future-looking discriminator value, decode gracefully (we don't care about exact behaviour, but it must not crash).
- `DefaultRetryClassifier` returns expected `isTransient` for every `VisualSemanticsError` case.
- `JobPriority` `Comparable` ordering.

### Phase 2 — Storage layer

- `SQLiteConnection` thin wrapper over `sqlite3_*` C APIs: `open`, `close`, `exec`, `prepare`, `step`, `finalize`, `transaction { … }`. Errors mapped to `VisualSemanticsError.storageFailure(reason:)`. PRAGMAs from §6 set on every open.
- `MigrationRunner` per §17. Migration array starts with the v1 schema as migration `1`. Schema version stored in `schema_meta`.
- `JobStore` actor with: `insert`, `coalescePending`, `selectActive(itemID:)`, `claimBatch(limit:now:)`, `transitionToCompleted`, `transitionToFailed`, `transitionToPending` (for retry), `transitionToCancelled`, `revertClaimNoAttemptBump` (for BG expiration), `resetStaleJobs`, `pendingCount`, `processingCount`, `failedCount`, `selectByJobID`.
- `ResultStore` actor with: `upsert`, `markConsumed`, `result(forItemID:)`, `pendingResults(limit:)`, `purgeExpired(now:purgeUnconsumed:)`, `pruneTerminalJobsOlderThan(_:)`.

**Tests for phase 2 (all use `:memory:` databases):**
- Migration from empty DB to v1 schema. Tables, indexes, and `schema_meta` row exist.
- Migration is idempotent — running twice does not double-apply.
- Downgrade detection: insert `schema_version='2'`, attempt to open at target=1, expect `.databaseSchemaIncompatible`.
- `claimBatch` with priority: high-priority pending jobs are claimed before normal-priority, even if older.
- `claimBatch` with backoff: rows where `next_attempt_at > now` are not claimed.
- `claimBatch` is atomic under contention: spawn 5 concurrent `claimBatch(limit:1)` calls against 5 pending rows; assert each claimer gets exactly one distinct row.
- Unique partial index: attempting to INSERT a second row with same `item_id` while first is `pending` fails with constraint error. Attempting after first transitions to `completed` succeeds.
- `coalescePending` correctly bumps priority when new is higher; refreshes `updated_at` only when new is lower or equal; resets `next_attempt_at` to 0 on priority bump.
- `resetStaleJobs` resets only rows older than threshold and only `processing` status.
- `purgeExpired`: parameterized over `purgeUnconsumed=true/false` × `consumed=0/1` × `expires_at past/future` (eight cases).
- WAL mode survives simulated crash: open DB, write rows, force-close without checkpoint, reopen, verify rows present.
- Realistic mock fixtures with timeouts, deserialization failure on corrupt JSON in `result_json` column.

### Phase 3 — Engine primitives

- `ProcessingGate` actor (`enter`/`leave`).
- `ResultBroadcaster` — choose between actor or `OSAllocatedUnfairLock`-backed implementation. Justify the choice in the commit message. Must support fan-out to N subscribers and graceful cleanup via `AsyncStream.onTermination`.
- `BatchProcessor` actor: tracks `[String: Task<Void, Never>]` (jobID → in-flight Task). `register`, `unregister`, `cancel(jobID:)`, `cancelAll`.
- `ManagedFileStore` actor: `writeData`, `deleteFile`, `sweepOrphans(referencedPaths:)`, atomic file writes, init creates the directory if missing.
- `SourceHasher`: hash function for `.fileURL` (using `inode + mtime + size`) and PHAsset (`localIdentifier + modificationDate`). Define `protocol SourceHashing` for testability.

**Tests for phase 3:**
- `ProcessingGate`: two concurrent `enter()` — exactly one returns `true`. After `leave()`, next `enter()` returns `true`.
- `ResultBroadcaster`: 100-subscriber fan-out. Cancel half mid-stream, broadcast 100 more, assert remaining 50 each receive 100 messages and removed continuations are gone.
- `ResultBroadcaster` memory test: subscribe/cancel 1,000 times in a loop, assert continuation dictionary returns to 0.
- `BatchProcessor`: register Task, call `cancel(jobID:)`, assert Task observes `Task.isCancelled`.
- `ManagedFileStore`: `writeData` produces an atomic file, `sweepOrphans` deletes only files not in the referenced set, write failure under simulated full disk throws `.storageFailure`.

### Phase 4 — Pipeline contracts and CompositePipeline

- All protocols from §5: `VisualSemanticsPipeline`, `ImageLoading`, `ImagePreprocessing`, `VisualLabelExtracting`, `ImageTypeDetecting`, `ImageQualityAnalyzing`, `VisualEmbeddingProviding`.
- Value types: `LoadedImage`, `PreprocessedImage`, `PipelineContext`, `PipelineOutput`.
- `CompositePipeline` (in core target) per §5. Per-stage `Task.checkCancellation()`. `async let` for stages that can run in parallel after labels are produced.

**Tests for phase 4 (all using mock pipeline components, no Vision yet):**
- `CompositePipeline` with all-success mocks produces expected `PipelineOutput`.
- Each stage failure (loader, preprocessor, label extractor, type detector, quality analyzer, embedding provider) propagates the typed error correctly.
- Cancellation between stages: cancel the parent Task between preprocess and labels; assert pipeline throws `CancellationError` and does not call later stages.
- Concurrency test: assert label extractor and quality analyzer overlap in time (instrumented mocks recording entry/exit timestamps).
- Empty labels are valid output, not an error.

### Phase 5 — Public facade

- `BGVisualSemanticsProcessor` final class per §2. Async init opens DB, runs migrations, calls `resetStaleJobs(threshold: now)`, calls `sweepOrphans`.
- All public methods wired to internal actors. Error paths typed.
- Enqueue path implements every branch from §9 (validation, batch dedup detection, `.data` materialisation, fileURL existence check, transactional coalesce/insert/reject, BGTask reschedule).
- Drain path implements §10. Foreground uses bounded-concurrency TaskGroup; background uses **single-job-claim loop** per the v1 commitment in diagram §25.3 (claim one job at a time, not a batch). Per-job timeout via `withThrowingTaskGroup`.
- Cancel path implements §11 with race-safe writeback: pipeline writeback checks DB status before writing.
- Lifecycle hooks (`applicationDidBecomeActive`, `applicationDidEnterBackground`).

**Tests for phase 5:**
- Every row in the §21 edge case matrix gets at least one corresponding test. The test names should reference the edge case number for traceability (`testEdgeCase_27_cancelProcessingWritesCancelledResultRaceSafe`).
- Enqueue: empty batch, intra-batch duplicates, missing file, processing-conflict rejection, coalesce-with-priority-bump, `.data` materialisation, disk-full on `.data` rejecting only that request.
- Drain: foreground concurrency cap honoured (instrument with mock pipeline that records concurrent invocations); transient retry sets `next_attempt_at` correctly; permanent error writes `failed` result; per-job timeout.
- Cancel: pending → cancelled (broadcast received); processing → cancelled (in-flight Task observes cancellation, writeback skipped); terminal job → `alreadyTerminal`; nonexistent → `notFound`.
- Stale recovery: insert `processing` rows with stale `updated_at`, init resets them.
- markConsumed idempotent on already-consumed and on nonexistent itemID.
- Streaming: factory pattern — two `makeResultStream()` calls produce two independent streams; both receive every broadcast; cancelling one does not affect the other.

### Phase 6 — BGTaskCoordinator

- `BGTaskCoordinator` per §12 with `register`, `scheduleIfNeeded`, `cancelScheduled`. `ExpirationToken` actor.
- BG drain integrates with `ExpirationToken` such that BG-expired jobs revert to pending without `attempt_count` increment, distinguished from user-cancel.
- Reschedule logic: after BG drain, if `pendingCount > 0` and not expired, submit a new request. Swallow `tooManyPendingTaskRequests`.

**Tests for phase 6:**
- Use a `BGTaskScheduler` test seam — wrap actual scheduler in a protocol you inject. Provide a `MockBGTaskScheduler` for tests.
- Expiration mid-job rolls back without attempt bump.
- Expiration between jobs leaves remaining pending unaffected.
- `tooManyPendingTaskRequests` is caught.
- Foreground drain in progress when BG fires: gate denies BG drain; BG `setTaskCompleted(success: true)` and reschedules.

### Phase 7 — Vision target

- `BGVisualSemanticsProcessorVision` target. Imports core, `Vision`, `ImageIO`, `Photos`, `CoreImage`.
- `DefaultImageLoader` per §19. `.fileURL`, `.phAssetLocalIdentifier`, `.data` (rejects with `.unsupportedImageSource` since `.data` should be resolved by `ManagedFileStore` upstream).
- `DefaultImagePreprocessor` per §19. Uses `CGImageSourceCreateThumbnailAtIndex`. Produces `CVPixelBuffer` (BGRA, IOSurface-backed).
- `VisionLabelExtractor` per §19. Pinned revision, `modelVersion = "vision-classify-r1"`. Confidence clamped to `[0, 1]`.
- `HeuristicImageTypeDetector` per §19. Aspect-ratio + corner-uniformity for screenshot, `VNDetectRectanglesRequest` + label hints for document/receipt.
- `BasicImageQualityAnalyzer` per §19. Laplacian variance for sharpness, `CIAreaAverage` for brightness. Raw values, no booleans.
- Convenience factory: `extension VisualSemanticsPipeline { static func defaultVision(...) -> CompositePipeline }` in the Vision target.

**Tests for phase 7:**
- Bundle a small test image set (5–10 fixtures): a screenshot, a document scan, a photo, a corrupt file, a tiny thumbnail.
- `DefaultImageLoader` succeeds on valid file, throws `.imageNotFound` on missing file, `.imageDecodeFailed` on corrupt bytes.
- `DefaultImagePreprocessor` downscales 4000×3000 to ≤1024 long edge, preserving aspect.
- `VisionLabelExtractor` returns labels with confidence in `[0, 1]`.
- `HeuristicImageTypeDetector` correctly classifies the fixtures.
- iCloud asset path: mock `PHImageManager` to simulate `isInCloud=true` + network disabled → throws `.imageNotFound`.

### Phase 8 — Integration tests and edge fuzz

- End-to-end: enqueue 1,000 items with mixed sources and priorities, run drains until empty, assert all 1,000 produce results with correct status.
- Crash recovery: spawn a subprocess that enqueues + starts a drain, kill it mid-flight, reopen DB in test process, assert recovery works.
- Stress: 50 concurrent enqueue calls + 5 concurrent drain calls against the same processor; assert no constraint violations, no double-claims, all jobs reach a terminal state.
- TTL sweep: insert 100 results with varying `expires_at` and `consumed`, advance the injected clock, assert sweep deletes the right subset.

### Phase 9 — Documentation and packaging

- DocC catalog for the public API. One symbol per public type and method.
- README.md with: quickstart, configuration walkthrough, lifecycle integration sample, common pitfalls.
- CHANGELOG.md with v1.0.0 entry.
- Verify `swift build` and `swift test` from clean checkout. Note any required Xcode version.

---

## Testing requirements (apply across all phases)

- **Coverage target:** every public method has at least one happy-path test and one failure-path test. Every error case in `VisualSemanticsError` is constructed and asserted somewhere.
- **No flaky tests.** If a test depends on timing, use the injected `DateProvider` and a `MockDateProvider`. Never use `Task.sleep` for control flow in tests; use `XCTestExpectation` or async sequences with deterministic mocks.
- **Realistic fixtures.** Mock pipeline components that fail on the third call, return empty labels, hang past the timeout, return malformed `VisualLabel` data — these reflect production failure modes.
- **Storage tests use `:memory:` databases** so they are hermetic and parallel-safe.
- **Deserialization failures.** Inject corrupted JSON into `result_json`; assert the store throws `.storageFailure` rather than crashing.
- **Concurrency stress.** Where a method touches shared state, write a test that calls it from `withTaskGroup` with at least 50 concurrent invocations and asserts invariants.

Run `swift test --parallel` after every phase. Do not move on if any test fails.

---

## Code style

- Public API surface uses `public` explicitly. Internal types are `internal` (the default — do not add the keyword unnecessarily).
- One type per file, named after the type.
- Folder layout matches §1 of the spec.
- Two-space indentation? **No — use four-space**, matching Apple's Swift conventions. (If `swift-format` is configured otherwise in the repo, follow that.)
- Acronyms in type names are capitalised per Swift conventions (`URL`, `JSON`, `ID`).
- No abbreviations in identifiers (`configuration`, not `cfg`).
- Errors thrown from non-public code are `internal` and may be enums local to the module; everything that crosses the module boundary maps to `VisualSemanticsError`.

---

## Open decisions to confirm before phase 1

The design doc §23 lists ten open decisions. Items 1–6 are locked in the spec. Items 7–10 you must confirm with the human before starting:

7. Stale results visible until overwritten — re-enqueue keeps the prior result visible to `result(for:)` until the new job completes. Confirm: yes / no.
8. `caches` directory (not `Documents`) for managed temp files. Confirm: yes / no.
9. Multi-process (app + extension on same DB) is **unsupported** in v1. Confirm: yes / no.
10. Pipeline confidence values outside `[0, 1]` are stored as-is, no validation by the engine. Confirm: yes / no.

Print these four questions back to the human and wait for answers before writing `Package.swift`.

---

## How to handle ambiguity

If the design doc is silent on a detail (e.g., the exact wording of a log event, the directory permissions on the managed temp dir):

- Make the most defensible choice given the rest of the design.
- Note the decision in the commit message: `decision: chose X because Y`.
- Continue.

If the design doc is **contradictory** or specifies something that conflicts with a hard constraint (e.g., asks for behaviour that breaks `Sendable`):

- Stop. Print the contradiction. Wait for the human to resolve.

If a phase reveals that an earlier phase's design needs revision:

- Stop. Summarise the issue, propose a revised design for the affected piece, wait for confirmation. Do not silently re-architect across phase boundaries.

---

## Definition of done

The library is done when:

1. `swift build` succeeds with no warnings under Swift 6 strict concurrency mode.
2. `swift test` passes with 100% of written tests.
3. Every public API symbol has DocC documentation.
4. The README quickstart runs verbatim against a fresh checkout.
5. All 50 rows of the §21 edge case matrix have at least one test referencing the row by number.
6. There are no `// TODO`, `// FIXME`, `// HACK`, or `fatalError("not implemented")` calls in production code paths.
7. There are zero inline `//` comments in any Swift file under `Sources/`.

---

## How to report progress

After each phase, produce a status report in this exact format:

```
PHASE N COMPLETE

Built:
- <module>: <one-line summary>
- <module>: <one-line summary>

Tests added: <count> across <files>
Tests passing: <count> / <count>

Decisions made:
- <decision>: <rationale>

Deviations from spec: <none | description>

Ready for phase N+1: <yes | needs human input on X>
```

Then stop and wait. Do not continue.

---

## Begin

1. Read `BGVisualSemanticsProcessor-design.md` end to end.
2. Print confirmations for open decisions 7–10.
3. Wait for the human's answers.
4. Begin phase 1.
