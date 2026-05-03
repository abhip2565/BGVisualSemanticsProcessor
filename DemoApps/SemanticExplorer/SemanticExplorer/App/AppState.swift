import Foundation
import SwiftUI
import Combine
import BGVisualSemanticsProcessor
import BGVisualSemanticsProcessorVision

/// Main application state for SemanticExplorer.
@MainActor
final class AppState: ObservableObject {
    @Published var specimens: [Specimen] = []
    @Published var isProcessorReady = false
    @Published var bgTaskRegistered = false

    private static let bgTaskIdentifier = "com.example.semanticexplorer.bgvs"

    private var processor: BGVisualSemanticsProcessor?
    private var coordinator: BGTaskCoordinator?
    private let specimenStore: SpecimenStore
    private var resultTask: Task<Void, Never>?

    init() {
        do {
            self.specimenStore = try SpecimenStore()
        } catch {
            fatalError("Failed to initialize SpecimenStore: \(error)")
        }
    }

    /// Must be called synchronously during App.init(), before the app finishes launching.
    static func registerBackgroundTask() {
        BGTaskCoordinator.registerHandler(identifier: bgTaskIdentifier)
    }

    /// Starts the processor and coordinator.
    func start() async {
        guard processor == nil else { return }

        do {
            let config = try VisualSemanticsConfiguration.default(
                backgroundTaskIdentifier: Self.bgTaskIdentifier
            )

            let processor = try BGVisualSemanticsProcessor.visionProcessor(config: config)
            self.processor = processor

            let coordinator = BGTaskCoordinator(identifier: Self.bgTaskIdentifier, processor: processor)
            await coordinator.register()
            self.coordinator = coordinator
            self.bgTaskRegistered = true

            self.isProcessorReady = true

            await processor.applicationDidBecomeActive()

            // Apply backlog
            await applyBacklog()

            // Start observing results
            observeResults()

            // Load existing specimens
            await refreshSpecimens()

        } catch {
            print("Failed to start processor: \(error)")
        }
    }
    
    private func observeResults() {
        guard let processor = processor else { return }
        
        resultTask?.cancel()
        resultTask = Task {
            for await result in await processor.makeResultStream() {
                await apply(result)
                try? await processor.markConsumed(itemIDs: [result.itemID])
            }
        }
    }
    
    private func applyBacklog() async {
        guard let processor = processor else { return }
        do {
            let backlog = try await processor.pendingResults(limit: 100)
            for result in backlog {
                await apply(result)
                try? await processor.markConsumed(itemIDs: [result.itemID])
            }
        } catch {
            print("Failed to apply backlog: \(error)")
        }
    }
    
    private func apply(_ result: VisualSemanticsResult) async {
        guard var specimen = await specimenStore.get(id: result.itemID) else { return }

        let json = encodePretty(result)
        print("--- RAW RESULT [\(result.itemID)] status=\(result.resultStatus) ---")
        print(json ?? "(encoding failed)")
        print("--- END RAW RESULT ---")

        switch result.resultStatus {
        case .completed:
            specimen.status = .completed
            specimen.imageType = result.imageType?.rawValue
            specimen.topLabels = result.labels
                .sorted { $0.confidence > $1.confidence }
                .prefix(5)
                .map { Specimen.LabelInfo(name: $0.name, confidence: $0.confidence) }
            specimen.sharpness = result.quality?.sharpness
            specimen.brightness = result.quality?.brightness
            specimen.rawResultJSON = json
        case .failed:
            specimen.status = .failed(reason: result.error?.message ?? "unknown")
        case .cancelled:
            specimen.status = .cancelled
        }
        
        await specimenStore.update(specimen)
        await refreshSpecimens()
    }
    
    func importImage(data: Data, urgently: Bool = false) async {
        let id = "specimen-\(UUID().uuidString)"
        let now = Date()
        let imageURL = await specimenStore.imageURL(for: id)
        
        let specimen = Specimen(
            id: id,
            imageURL: imageURL,
            createdAt: now,
            status: .queued,
            topLabels: []
        )
        
        do {
            try await specimenStore.add(specimen, imageData: data)
            await refreshSpecimens()
            
            guard let processor = processor else { 
                throw VisualSemanticsError.configurationInvalid(reason: "Processor not initialized")
            }
            
            let request = EnqueueRequest(
                itemID: id,
                source: .data(data, suggestedExtension: "jpg"),
                priority: urgently ? .high : .normal
            )
            
            let outcome = try await processor.enqueue([request])

            if outcome.enqueued.contains(id) {
                var updated = specimen
                updated.status = .processing
                await specimenStore.update(updated)
                await refreshSpecimens()

                try await processor.drain(mode: .foreground)
            }
        } catch {
            var failed = specimen
            failed.status = .failed(reason: error.localizedDescription)
            await specimenStore.update(failed)
            await refreshSpecimens()
        }
    }
    
    func clearAll() async {
        // 1. Cancel all in processor
        let activeIDs = specimens.map { $0.id }
        _ = try? await processor?.cancel(itemIDs: activeIDs)
        _ = try? await processor?.cancelAllPending()
        
        // 2. Clear store
        await specimenStore.clear()
        
        // 3. Refresh UI
        await refreshSpecimens()
    }

    func cancel(id: String) async {
        _ = try? await processor?.cancel(itemIDs: [id])
        // The results stream will eventually broadcast a cancellation, but we can optimistically update
        if var specimen = await specimenStore.get(id: id) {
            specimen.status = .cancelled
            await specimenStore.update(specimen)
            await refreshSpecimens()
        }
    }

    func reEnqueue(specimen: Specimen) async {
        do {
            let data = try Data(contentsOf: specimen.imageURL)
            await importImage(data: data)
        } catch {
            print("Failed to re-enqueue: \(error)")
        }
    }
    
    private func refreshSpecimens() async {
        let all = await specimenStore.all()
        self.specimens = all
    }
    
    // Lifecycle hooks
    func applicationDidBecomeActive() {
        Task {
            await processor?.applicationDidBecomeActive()
        }
    }
    
    func applicationDidEnterBackground() {
        Task {
            await processor?.applicationDidEnterBackground()
        }
    }

    func scheduleBackgroundTask() async {
        await coordinator?.scheduleProcessing()
    }
    
    private func encodePretty(_ result: VisualSemanticsResult) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(result) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
