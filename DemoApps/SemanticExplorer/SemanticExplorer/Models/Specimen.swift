import Foundation

/// Represents an image specimen and its associated semantic analysis.
struct Specimen: Identifiable, Sendable, Hashable {
    let id: String              // matches library itemID, "specimen-<uuid>"
    let imageURL: URL           // file in caches dir
    let createdAt: Date
    var status: SpecimenStatus
    var imageType: String?
    var topLabels: [LabelInfo]
    var sharpness: Double?
    var brightness: Double?
    var rawResultJSON: String?

    struct LabelInfo: Sendable, Hashable {
        let name: String
        let confidence: Double
    }
}
