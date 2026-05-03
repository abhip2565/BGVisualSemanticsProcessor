import SwiftUI

/// A comprehensive view for a specimen, showing all analysis data and providing controls.
struct SpecimenDetailView: View {
    @EnvironmentObject var appState: AppState
    let specimen: Specimen
    
    @State private var isDebugExpanded = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Image Section
                ZStack {
                    AsyncImage(url: specimen.imageURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.05))
                .border(Color.primary.opacity(0.1), width: 1)
                
                // Status Header
                HStack {
                    statusPill
                    
                    if let type = specimen.imageType {
                        Text(type.uppercased())
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    
                    Spacer()
                    
                    controls
                }
                
                // Analysis Data
                VStack(alignment: .leading, spacing: 16) {
                    if !specimen.topLabels.isEmpty {
                        SectionHeader(title: "SEMANTIC LABELS")
                        
                        VStack(spacing: 8) {
                            ForEach(specimen.topLabels, id: \.name) { label in
                                LabelRow(name: label.name, confidence: label.confidence)
                            }
                        }
                    }
                    
                    if specimen.sharpness != nil || specimen.brightness != nil {
                        SectionHeader(title: "IMAGE QUALITY")
                        
                        HStack(spacing: 20) {
                            if let sharpness = specimen.sharpness {
                                MetricView(title: "SHARPNESS", value: String(format: "%.3f", sharpness))
                            }
                            if let brightness = specimen.brightness {
                                MetricView(title: "BRIGHTNESS", value: String(format: "%.3f", brightness))
                            }
                        }
                    }
                }
                
                // Debug Section
                if let json = specimen.rawResultJSON {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation { isDebugExpanded.toggle() }
                        } label: {
                            HStack {
                                SectionHeader(title: "RAW RESULT JSON")
                                Spacer()
                                Image(systemName: isDebugExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        if isDebugExpanded {
                            Text(json)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
        }
        .navigationTitle("SPECIMEN ANALYSIS")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.1))
        .foregroundColor(statusColor)
        .cornerRadius(20)
    }
    
    @ViewBuilder
    private var controls: some View {
        if specimen.status == .queued || specimen.status == .processing {
            Button("CANCEL") {
                Task { await appState.cancel(id: specimen.id) }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.red)
        } else {
            Button("RE-ENQUEUE") {
                Task { await appState.reEnqueue(specimen: specimen) }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.blue)
        }
    }
    
    private var statusColor: Color {
        switch specimen.status {
        case .queued: return .gray
        case .processing: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
    
    private var statusText: String {
        switch specimen.status {
        case .queued: return "Queued"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .failed(let reason): return "Failed: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.bottom, 4)
    }
}

private struct LabelRow: View {
    let name: String
    let confidence: Double
    
    var body: some View {
        HStack {
            Text(name.uppercased())
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Spacer()
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 80, height: 4)
                Rectangle()
                    .fill(Color.green)
                    .frame(width: CGFloat(80 * confidence), height: 4)
            }
            Text(String(format: "%.0f%%", confidence * 100))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(width: 45, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

private struct MetricView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .light, design: .monospaced))
        }
    }
}
