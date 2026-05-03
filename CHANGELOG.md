# Changelog

All notable changes to the **BGVisualSemanticsProcessor** library will be documented in this file.

## [1.0.0] - 2026-05-02

### Added
- **Core Engine**: `BGVisualSemanticsProcessor` coordinator for asynchronous visual analysis.
- **Storage Layer**: SQLite-backed persistent job queue and result store with WAL mode.
- **Concurrency**: Swift 6 actor-based architecture for thread-safe operations.
- **Vision Integration**: 
    - `VisionImageLoader` for File, Data, and PHAsset sources.
    - `VisionImagePreprocessor` for Core Image-based normalization.
    - `VisionLabelExtractor` using `VNClassifyImageRequest`.
    - `VisionImageTypeDetector` for taxonomy classification.
- **Background Support**: `BGTaskCoordinator` for integration with Apple's `BackgroundTasks` framework.
- **Engine Primitives**: `ProcessingGate`, `ResultBroadcaster`, `BatchProcessor`, and `ManagedFileStore`.
- **Testing**: Comprehensive 40+ test suite covering stress, concurrency, and integration.

### Features
- Asynchronous image processing from diverse sources.
- Persistent results with configurable TTL and auto-purging.
- Real-time result observation via `AsyncStream`.
- Automatic retry logic for transient pipeline failures.
- Robust state recovery on app launch.
