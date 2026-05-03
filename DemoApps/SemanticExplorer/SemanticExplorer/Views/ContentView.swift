import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ImportControls()
                
                SpecimenGridView()
                
                if !appState.isProcessorReady {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("INITIALIZING ENGINE...")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.yellow.opacity(0.1))
                }
                
                bgStatusFooter
            }
            .navigationTitle("SEMANTIC EXPLORER")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Specimen.self) { specimen in
                SpecimenDetailView(specimen: specimen)
            }
        }
    }
    
    private var bgStatusFooter: some View {
        HStack {
            Text("BG TASK:")
            Text("com.example.semanticexplorer.bgvs")
                .foregroundColor(.blue)
            Spacer()
            Text("REGISTERED:")
            Text(appState.bgTaskRegistered ? "YES" : "NO")
                .foregroundColor(appState.bgTaskRegistered ? .green : .red)
        }
        .font(.system(size: 8, weight: .bold, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .tertiarySystemBackground))
        .border(Color.primary.opacity(0.05), width: 1)
    }
}

#Preview {
    ContentView()
}
