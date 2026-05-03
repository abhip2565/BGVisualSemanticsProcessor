import Foundation

/// Provider for current date.
public protocol DateProvider: Sendable {
    func now() -> Date
}

/// System implementation of date provider.
public struct SystemDateProvider: DateProvider {
    public init() {}
    public func now() -> Date {
        Date()
    }
}
