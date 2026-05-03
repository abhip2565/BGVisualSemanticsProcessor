# SemanticExplorer — Demo App Implementation Prompt

You are building a SwiftUI demo iOS app that exercises the `BGVisualSemanticsProcessor` Swift package. Read `BGVisualSemanticsProcessor-design.md` first to confirm the real API surface — the rest of this prompt assumes you've read it.

The app is a **library demo, not a product.** Its only job is to prove the library can: ingest images, enqueue jobs, stream results, and survive background/foreground transitions.

---

## Hard constraints

- iOS 16+, SwiftUI, Swift 6 strict concurrency.
- Zero third-party dependencies.
- No SQLite, no Core Data, no SwiftData in the app. Library owns storage; app keeps an in-memory specimen list + image files in caches dir.
- No `// ` inline comments anywhere. DocC `///` only on public-ish types.
- No force unwraps in app code (tests can).
- Use the real library API verbatim. Do not invent method names.

## Library API reference (from spec)

```swift
let processor = try await BGVisualSemanticsProcessor(
    configuration: .default(
        databaseLocation: .default,
        backgroundTaskIdentifier: "com.example.semanticexplorer.bgvs"
    ),
    pipeline: .defaultVision()  // from BGVisualSemanticsProcessorVision
)

try await processor.enqueue([
    EnqueueRequest(itemID: "specimen-<uuid>", source: .data(imageData, suggestedExtension: "jpg"), priority: .normal)
])

for await result in processor.makeResultStream() {
    // result.itemID, .resultStatus, .imageType, .labels, .quality
}

try await processor.markConsumed(itemIDs: [result.itemID])

await processor.applicationDidBecomeActive()
await processor.applicationDidEnterBackground()
```

`JobPriority` is `.low | .normal | .high`. There is no `.userInitiated` or `.background`. The toggle in the UI maps to `.high` vs `.normal` — frame it as **"Process urgently"**, not "Background mode."

`BGTaskCoordinator` is constructed, not a singleton:

```swift
let coordinator = BGTaskCoordinator(identifier: "com.example.semanticexplorer.bgvs", processor: processor)
coordinator.register()  // call once at app launch
```

---

## File layout

```
SemanticExplorer/
├── SemanticExplorerApp.swift
├── App/
│   ├── AppState.swift
│   └── SpecimenStore.swift
├── Models/
│   ├── Specimen.swift
│   └── SpecimenStatus.swift
├── Views/
│   ├── ContentView.swift
│   ├── SpecimenGridView.swift
│   ├── SpecimenCardView.swift
│   ├── SpecimenDetailView.swift
│   └── ImportControls.swift
├── Imports/
│   └── CameraPicker.swift
└── Utilities/
    └── ThumbnailGenerator.swift
```

`Info.plist` keys:
- `NSPhotoLibraryUsageDescription`
- `NSCameraUsageDescription`
- `UIBackgroundModes` → `["processing"]`
- `BGTaskSchedulerPermittedIdentifiers` → `["com.example.semanticexplorer.bgvs"]`

---

## Models

```swift
struct Specimen: Identifiable, Sendable, Hashable {
    let id: String              // matches library itemID, "specimen-<uuid>"
    let imageURL: URL           // file in caches dir
    let createdAt: Date
    var status: SpecimenStatus
    var imageType: String?
    var topLabels: [(name: String, confidence: Double)]
    var sharpness: Double?
    var brightness: Double?
    var rawResultJSON: String?
}

enum SpecimenStatus: Sendable, Equatable {
    case queued
    case processing
    case completed
    case failed(reason: String)
    case cancelled
}
```

`Specimen` carries the same `id` the library sees — that's the only sane mapping. Generate one UUID, use it for the file name and the library `itemID`.

---

## Build phases

Stop and run `xcodebuild build` after each phase. Do not move on if it fails.

### Phase 1 — Skeleton
- New SwiftUI iOS app target `SemanticExplorer`.
- Add local SwiftPM dependency on `BGVisualSemanticsProcessor` and `BGVisualSemanticsProcessorVision`.
- Set Swift 6 strict concurrency in build settings.
- Add Info.plist keys above.
- Empty `ContentView` showing `Text("hello")`. Build and run on simulator.

### Phase 2 — AppState + processor wiring
- Build `SpecimenStore`: actor that owns `[id: Specimen]`, persists images to `<caches>/SemanticExplorer/images/<id>.jpg`, generates thumbnails on demand. Expose `add`, `update`, `all`, `remove`.
- Build `AppState`: `@MainActor final class`, `ObservableObject`, owns the `BGVisualSemanticsProcessor` (lazily initialised in `start()` since init is `async throws`). Owns the result-stream Task.
- `start()` is called by `SemanticExplorerApp` in `.task` modifier on root view. Inside: build processor, build coordinator, register coordinator, call `applicationDidBecomeActive`, start `observeResults()`.
- `observeResults()` subscribes to `processor.makeResultStream()`, hops to the main actor, calls `apply(_ result:)`, then awaits `processor.markConsumed`.
- Apply backlog on start: call `processor.pendingResults()` once before subscribing, apply each, then `markConsumed`. (Yes, this duplicates with the stream for results that arrive between the two calls — `apply` is idempotent.)
- Lifecycle: use SwiftUI `ScenePhase` in `SemanticExplorerApp` to route `.active` → `applicationDidBecomeActive`, `.background` → `applicationDidEnterBackground`.

### Phase 3 — Image ingestion
- `ImportControls` view: `PhotosPicker` (multi-select up to 10), "Take Photo" button, "Process urgently" toggle, "Clear" button.
- Camera: `CameraPicker` is `UIViewControllerRepresentable` over `UIImagePickerController` (sourceType `.camera`). Returns `Data` (JPEG, 0.85 quality).
- On selection: `await appState.importImage(data:)`. That method generates a UUID, persists to caches via `SpecimenStore`, inserts a `Specimen(status: .queued)`, calls `processor.enqueue([EnqueueRequest(itemID: id, source: .data(data, suggestedExtension: "jpg"), priority: toggle ? .high : .normal)])`, then transitions specimen to `.processing` if outcome.enqueued contains the id (or stays `.queued` if coalesced — shouldn't happen on fresh ids).
- Errors during import → set specimen status to `.failed(reason:)` with the human-readable reason.

### Phase 4 — Grid UI
- `ContentView`: NavigationStack, `ImportControls` at top, `SpecimenGridView` below.
- `SpecimenGridView`: `LazyVGrid` with adaptive columns (~120pt). Driven by `appState.specimens` sorted newest-first.
- `SpecimenCardView`: thumbnail (loaded from caches via `ThumbnailGenerator`), status badge (color-coded: gray queued, blue processing, green completed, red failed, yellow cancelled), top label name + confidence as a single line, image type pill.
- Tap → push `SpecimenDetailView`.

### Phase 5 — Detail UI
- `SpecimenDetailView`: full image, status row, type, all labels (sorted by confidence desc), quality (sharpness/brightness raw values), and a collapsible "Debug" section showing pretty-printed `rawResultJSON`.
- "Cancel" button visible while status is `.queued` or `.processing` → calls `processor.cancel(itemIDs: [specimen.id])`.
- "Re-enqueue" button visible on terminal states → re-imports the existing image file as a new specimen (new UUID).

### Phase 6 — BG demo affordance
- Add a "Schedule BG Task" debug button (only in `#if DEBUG`) that does nothing in production code but logs a hint:
  ```
  print("Trigger BG run via lldb: e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"com.example.semanticexplorer.bgvs\"]")
  ```
- Show a small status line: "BG task identifier: …, registered: yes".
- Document in README: BG task cannot be reliably triggered without lldb in dev. The demo proves the registration + scheduling path; iOS decides when it actually runs.

### Phase 7 — Polish + verification checklist
- Empty state for grid ("No specimens yet — pick a photo or take one").
- Confirm-clear alert on "Clear" (deletes all specimens + image files + calls `processor.cancelAllPending()`).
- README section: how to run, how to grant permissions, how to trigger BG task in lldb.

---

## Result → Specimen mapping

```swift
@MainActor
private func apply(_ result: VisualSemanticsResult) async {
    guard var specimen = await specimenStore.get(id: result.itemID) else { return }
    switch result.resultStatus {
    case .completed:
        specimen.status = .completed
        specimen.imageType = result.imageType?.rawValue
        specimen.topLabels = result.labels
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { ($0.name, $0.confidence) }
        specimen.sharpness = result.quality?.sharpness
        specimen.brightness = result.quality?.brightness
        specimen.rawResultJSON = encodePretty(result)
    case .failed:
        specimen.status = .failed(reason: result.error?.message ?? "unknown")
    case .cancelled:
        specimen.status = .cancelled
    }
    await specimenStore.update(specimen)
    objectWillChange.send()
}
```

`apply` is idempotent — calling it twice with the same result is fine.

---

## Verification

Manual checks before declaring done:

1. Pick a photo → grid card appears as `queued`, transitions to `processing`, then `completed` with labels.
2. Pick 5 photos at once → all process, none lost.
3. Pick a photo, immediately tap Cancel on the detail screen → status becomes `cancelled`.
4. Force-quit the app while a job is processing → reopen, specimen recovers (library handles stale recovery; backlog is loaded via `pendingResults`).
5. Toggle "Process urgently" on, pick a photo while another is mid-process → priority is `.high` in the enqueue call (verify via logger).
6. Trigger BG task via lldb command → drain runs, results stream in.
7. No warnings in Swift 6 strict concurrency build.

---

## Out of scope for v1

- Search, filtering, persistence beyond image files, dashboards, sync, multi-device, sharing, exports, settings screen.
- Don't add them. The demo's purpose is to validate the library, not become a product.

---

## Begin

1. Confirm you've read `BGVisualSemanticsProcessor-design.md`.
2. Run phase 1. Stop. Report.
3. Wait for go-ahead before phase 2.
