import Foundation

/// Priority for a visual semantics job.
public enum JobPriority: Int, Codable, Sendable, Comparable, Equatable {
    case low = 0
    case normal = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
