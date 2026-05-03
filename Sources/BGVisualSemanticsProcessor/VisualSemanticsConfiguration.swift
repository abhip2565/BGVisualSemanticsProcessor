import Foundation

/// Configuration for the visual semantics processor.
public struct VisualSemanticsConfiguration: Sendable {
    public let databaseLocation: DatabaseLocation
    public let backgroundTaskIdentifier: String?
    public let resultTTL: TimeInterval
    public let foregroundBatchSize: Int
    public let backgroundBatchSize: Int
    public let foregroundConcurrency: Int
    public let perJobTimeout: TimeInterval
    public let maxAttempts: Int
    public let staleProcessingTimeout: TimeInterval
    public let retry: RetryPolicy
    public let maxImageDimension: Int
    public let phAssetNetworkAccessForeground: Bool
    public let phAssetNetworkAccessBackground: Bool
    public let managedTempDirectoryName: String
    public let purgeUnconsumedExpiredResults: Bool

    public init(
        databaseLocation: DatabaseLocation = .default,
        backgroundTaskIdentifier: String? = nil,
        resultTTL: TimeInterval = 86_400,
        foregroundBatchSize: Int = 30,
        backgroundBatchSize: Int = 5,
        foregroundConcurrency: Int = 3,
        perJobTimeout: TimeInterval = 30,
        maxAttempts: Int = 3,
        staleProcessingTimeout: TimeInterval = 15 * 60,
        retry: RetryPolicy = .init(baseDelay: 30, maxDelay: 3600, jitterFraction: 0.2),
        maxImageDimension: Int = 1024,
        phAssetNetworkAccessForeground: Bool = true,
        phAssetNetworkAccessBackground: Bool = false,
        managedTempDirectoryName: String = "BGVisualSemanticsProcessor",
        purgeUnconsumedExpiredResults: Bool = true
    ) throws {
        // Validation per §3
        if foregroundBatchSize < 1 {
            throw VisualSemanticsError.configurationInvalid(reason: "foregroundBatchSize must be >= 1")
        }
        if backgroundBatchSize < 1 {
            throw VisualSemanticsError.configurationInvalid(reason: "backgroundBatchSize must be >= 1")
        }
        if foregroundConcurrency < 1 {
            throw VisualSemanticsError.configurationInvalid(reason: "foregroundConcurrency must be >= 1")
        }
        if maxAttempts < 1 {
            throw VisualSemanticsError.configurationInvalid(reason: "maxAttempts must be >= 1")
        }
        if perJobTimeout <= 0 {
            throw VisualSemanticsError.configurationInvalid(reason: "perJobTimeout must be > 0")
        }

        self.databaseLocation = databaseLocation
        self.backgroundTaskIdentifier = backgroundTaskIdentifier
        self.resultTTL = resultTTL
        self.foregroundBatchSize = foregroundBatchSize
        self.backgroundBatchSize = backgroundBatchSize
        self.foregroundConcurrency = foregroundConcurrency
        self.perJobTimeout = perJobTimeout
        self.maxAttempts = maxAttempts
        self.staleProcessingTimeout = staleProcessingTimeout
        self.retry = retry
        self.maxImageDimension = maxImageDimension
        self.phAssetNetworkAccessForeground = phAssetNetworkAccessForeground
        self.phAssetNetworkAccessBackground = phAssetNetworkAccessBackground
        self.managedTempDirectoryName = managedTempDirectoryName
        self.purgeUnconsumedExpiredResults = purgeUnconsumedExpiredResults
    }
}

public enum DatabaseLocation: Sendable {
    case `default`
    case path(String)
    case inMemory
}

public struct RetryPolicy: Sendable {
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterFraction: Double

    public init(baseDelay: TimeInterval, maxDelay: TimeInterval, jitterFraction: Double) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
    }
}

public extension VisualSemanticsConfiguration {
    static func `default`(
        databaseLocation: DatabaseLocation = .default,
        backgroundTaskIdentifier: String? = nil
    ) throws -> Self {
        try .init(
            databaseLocation: databaseLocation,
            backgroundTaskIdentifier: backgroundTaskIdentifier
        )
    }
}
