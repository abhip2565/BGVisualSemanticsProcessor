import SwiftUI

/// A grid view that displays all specimens managed by the AppState.
struct SpecimenGridView: View {
    @EnvironmentObject var appState: AppState
    
    let columns = [
        GridItem(.adaptive(minimum: 120), spacing: 12)
    ]
    
    var body: some View {
        if appState.specimens.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(appState.specimens) { specimen in
                        NavigationLink(value: specimen) {
                            SpecimenCardView(specimen: specimen)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.dashed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("NO SPECIMENS")
                    .font(.system(.headline, design: .monospaced))
                
                Text("Pick a photo or take one to begin analysis")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
