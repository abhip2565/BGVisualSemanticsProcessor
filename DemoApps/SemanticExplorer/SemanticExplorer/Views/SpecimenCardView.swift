import SwiftUI

/// A card representing a single image specimen with its status and top label.
struct SpecimenCardView: View {
    let specimen: Specimen
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Z_WEAK_IMAGE_HOLDER {
                if let thumbnail = ThumbnailGenerator.generateThumbnail(for: specimen.imageURL) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        }
                }
            }
            .frame(height: 120)
            .clipped()
            .border(Color.primary.opacity(0.1), width: 1)
            .overlay(alignment: .topTrailing) {
                statusBadge
                    .padding(4)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if let firstLabel = specimen.topLabels.first {
                    Text(firstLabel.name.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                    
                    Text("\(Int(firstLabel.confidence * 100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text(specimen.status == .processing ? "ANALYZING..." : "PENDING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                if let type = specimen.imageType {
                    Text(type.uppercased())
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1))
                        .cornerRadius(2)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .border(Color.primary.opacity(0.05), width: 1)
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .shadow(color: statusColor.opacity(0.5), radius: 2)
    }
    
    private var statusColor: Color {
        switch specimen.status {
        case .queued: return .gray
        case .processing: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        }
    }
}

private struct Z_WEAK_IMAGE_HOLDER<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        ZStack {
            content()
        }
    }
}
