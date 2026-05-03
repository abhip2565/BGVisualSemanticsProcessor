import SwiftUI
import PhotosUI

/// Controls for importing images from the library or camera.
struct ImportControls: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isCameraPresented = false
    @State private var processUrgently = false
    @State private var isClearing = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                // Photos Library Picker
                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 10,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .onChange(of: selectedItems) { newItems in
                    Task {
                        await handlePhotosSelection(newItems)
                        selectedItems = [] // Reset for next selection
                    }
                }

                // Camera Button
                Button {
                    isCameraPresented = true
                } label: {
                    Label("Camera", systemImage: "camera")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }

            HStack {
                Toggle("Process urgently", isOn: $processUrgently)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                #if DEBUG
                Button {
                    print("--- BACKGROUND TASK DEBUG HINT ---")
                    print("Trigger BG run via lldb: e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"com.example.semanticexplorer.bgvs\"]")
                    print("----------------------------------")
                    Task {
                        await appState.scheduleBackgroundTask()
                    }
                } label: {
                    Image(systemName: "clock.badge.play")
                        .font(.subheadline)
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .foregroundColor(.orange)
                        .cornerRadius(6)
                }
                .help("Simulate Background Task scheduling")
                #endif

                Button(role: .destructive) {
                    isClearing = true
                } label: {
                    Text("Clear All")
                        .font(.subheadline)
                }
                .alert("Clear Specimens?", isPresented: $isClearing) {
                    Button("Clear", role: .destructive) {
                        Task { await appState.clearAll() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will delete all processed data and image files.")
                }
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .sheet(isPresented: $isCameraPresented) {
            CameraPicker { data in
                Task {
                    await appState.importImage(data: data, urgently: processUrgently)
                }
            } onFailure: { error in
                print("Camera failed: \(error)")
            }
        }
    }

    private func handlePhotosSelection(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await appState.importImage(data: data, urgently: processUrgently)
            }
        }
    }
}
