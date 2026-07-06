import Foundation

/// How a strategy actually gets its data. Recorded on results for diagnostics.
public enum ProviderFetchKind: String, Sendable {
    case api, oauth, web, cli, mock
}

/// Everything a strategy needs, passed by value so fetches run off the main actor.
public struct ProviderFetchContext: Sendable {
    public let provider: UsageProvider
    public let now: Date
    public let credential: String?   // API key / token, resolved by the app layer

    public init(provider: UsageProvider, now: Date, credential: String? = nil) {
        self.provider = provider
        self.now = now
        self.credential = credential
    }
}

public struct ProviderFetchResult: Sendable {
    public let usage: UsageSnapshot
    public let sourceLabel: String

    public init(usage: UsageSnapshot, sourceLabel: String) {
        self.usage = usage
        self.sourceLabel = sourceLabel
    }
}

public enum ProviderFetchError: LocalizedError, Sendable {
    case noStrategyAvailable(UsageProvider)
    case missingCredential(UsageProvider)

    public var errorDescription: String? {
        switch self {
        case .noStrategyAvailable(let p): "No available fetch strategy for \(p.rawValue)."
        case .missingCredential(let p): "Missing credential for \(p.rawValue)."
        }
    }
}

/// The one behavior each data source implements. Kept intentionally small: a
/// strategy knows how to check availability and fetch, and whether a failure
/// should fall through to the next strategy.
public protocol ProviderFetchStrategy: Sendable {
    var id: String { get }
    var kind: ProviderFetchKind { get }
    func isAvailable(_ context: ProviderFetchContext) async -> Bool
    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult
    func shouldFallback(on error: Error) -> Bool
}

extension ProviderFetchStrategy {
    public func isAvailable(_ context: ProviderFetchContext) async -> Bool { true }
    public func shouldFallback(on error: Error) -> Bool { true }
}

/// Runs strategies in priority order: the first available one that succeeds
/// wins; on error it falls back to the next (if allowed). Cancellation-aware.
public struct ProviderFetchPipeline: Sendable {
    public let resolveStrategies: @Sendable (ProviderFetchContext) -> [any ProviderFetchStrategy]

    public init(resolveStrategies: @escaping @Sendable (ProviderFetchContext) -> [any ProviderFetchStrategy]) {
        self.resolveStrategies = resolveStrategies
    }

    public func fetch(_ context: ProviderFetchContext) async -> Result<ProviderFetchResult, Error> {
        var lastError: Error?
        for strategy in resolveStrategies(context) {
            if Task.isCancelled { return .failure(CancellationError()) }
            guard await strategy.isAvailable(context) else { continue }
            do {
                return .success(try await strategy.fetch(context))
            } catch {
                if error is CancellationError { return .failure(error) }
                lastError = error
                if strategy.shouldFallback(on: error) { continue }
                return .failure(error)
            }
        }
        return .failure(lastError ?? ProviderFetchError.noStrategyAvailable(context.provider))
    }
}
