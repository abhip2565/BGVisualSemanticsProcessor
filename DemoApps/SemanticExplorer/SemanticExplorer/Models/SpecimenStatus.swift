import Foundation

/// Represents a processing status for a specimen.
enum SpecimenStatus: Sendable, Equatable, Hashable {
    case queued
    case processing
    case completed
    case failed(reason: String)
    case cancelled
}
