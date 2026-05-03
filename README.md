# BGVisualSemanticsProcessor

A production-grade iOS library for asynchronous, persistent visual semantics processing. Designed for high performance, battery efficiency, and thread safety using **Swift 6 strict concurrency**.

## Features

- ⚡️ **Asynchronous Orchestration**: Enqueue hundreds of images without blocking the main thread.
- 🔋 **Background Optimized**: Built-in support for `BGProcessingTask` to run heavy analysis while the device charges.
- 💾 **Robust Persistence**: SQLite-backed storage ensures no jobs are lost if the app is terminated.
- 🔍 **Vision Powered**: Automatic labeling, type detection (screenshot/document/receipt), and quality analysis.
- 🧵 **Swift 6 Ready**: Actor-isolated state and `Sendable` value types throughout.
- 📦 **Zero Dependencies**: Pure Swift implementation using only Apple system frameworks.

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-repo/BGVisualSemanticsProcessor.git", from: "1.0.0")
]
```

## Architecture

The library is split into two targets:

1. **`BGVisualSemanticsProcessor`**: The core engine, database management, and state machine.
2. **`BGVisualSemanticsProcessorVision`**: Concrete implementations of loading and analysis using Apple's Vision and Photos frameworks.

## Quick Start

### 1. Basic Initialization

Initialize the processor using the default Vision-backed pipeline:

```swift
import BGVisualSemanticsProcessor
import BGVisualSemanticsProcessorVision

// Standard configuration
let config = try VisualSemanticsConfiguration.default()

// Create the processor
let processor = try BGVisualSemanticsProcessor.visionProcessor(config: config)
```

### 2. Integration with App Lifecycle

Register the background coordinator to allow analysis to run while the app is backgrounded.

```swift
// In your App or AppDelegate
let coordinator = BGTaskCoordinator(
    processor: processor, 
    taskIdentifier: "com.yourapp.visualAnalysis"
)

func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
    coordinator.registerHandlers()
    return true
}
```

### 3. Enqueueing Items

```swift
let requests = [
    EnqueueRequest(itemID: "photo_1", source: .fileURL(path: localPath)),
    EnqueueRequest(itemID: "photo_2", source: .phAssetLocalIdentifier(assetID), priority: .high)
]

let outcome = try await processor.enqueue(requests)
print("Enqueued \(outcome.enqueued.count) items")
```

### 4. Observing Results

Use `resultsStream()` to receive updates in real-time as they are processed.

```swift
Task {
    for await result in await processor.resultsStream() {
        if result.resultStatus == .completed {
            print("Item \(result.itemID) identified as \(result.imageType ?? .unknown)")
            print("Labels: \(result.labels.map { $0.name }.joined(separator: ", "))")
            
            // Mark as consumed to allow cleanup later
            try await processor.markConsumed(itemIDs: [result.itemID])
        }
    }
}
```

## Configuration

The `VisualSemanticsConfiguration` allows fine-tuning:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `foregroundBatchSize` | 30 | Max items claimed per foreground drain. |
| `backgroundBatchSize` | 5 | Max items claimed per background task window. |
| `resultTTL` | 86,400s | How long results persist in the DB. |
| `maxAttempts` | 3 | Retries for transient failures. |
| `maxImageDimension` | 1024 | Image scale limit for analysis. |

## License

Distributed under the MIT License. See `LICENSE` for more information.

---

## SemanticExplorer Demo App

The repository includes a **SemanticExplorer** iOS app to demonstrate the library's capabilities.

### Features
- **Live Analysis**: Visualizes real-time extraction of semantic labels and image types.
- **Job Control**: Manually cancel active processing or re-enqueue existing specimens.
- **Background Simulation**: Includes debug affordances to trigger background task logic.

### How to Run
1. Open the project in Xcode (16.0+).
2. Select the **SemanticExplorer** scheme.
3. Run on an **iPhone 16 Simulator** or physical device (iOS 16.0+).
4. Grant **Camera** and **Photo Library** permissions when prompted.

### Triggering Background Processing
Because iOS background tasks are system-scheduled, you can use `lldb` to force a run in the simulator:
1. Tap the **Clock Badge** button in the app's top control bar to schedule the task.
2. Background the app (Cmd+Shift+H).
3. In Xcode's console, pause execution and run:
   ```lldb
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.example.semanticexplorer.bgvs"]
   ```
4. Resume execution. The library will begin its background drain sequence.
