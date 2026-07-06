import Foundation

/// Static display/branding data for a provider (no behavior).
public struct ProviderMetadata: Sendable {
    public let displayName: String
    public let accent: RGB
    public let supportsWeekly: Bool

    public struct RGB: Sendable {
        public let r, g, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    }

    public init(displayName: String, accent: RGB, supportsWeekly: Bool) {
        self.displayName = displayName
        self.accent = accent
        self.supportsWeekly = supportsWeekly
    }
}

/// A provider = static metadata + a fetch pipeline. All UI lives in the app;
/// this stays UI-agnostic so the same descriptor works for a CLI later.
public struct ProviderDescriptor: Sendable {
    public let id: UsageProvider
    public let metadata: ProviderMetadata
    public let pipeline: ProviderFetchPipeline

    public init(id: UsageProvider, metadata: ProviderMetadata, pipeline: ProviderFetchPipeline) {
        self.id = id
        self.metadata = metadata
        self.pipeline = pipeline
    }

    public func fetch(now: Date, credential: String? = nil) async -> Result<ProviderFetchResult, Error> {
        await pipeline.fetch(ProviderFetchContext(provider: id, now: now, credential: credential))
    }
}

/// The one list the app iterates over. Add a descriptor here for every
/// `UsageProvider` case — `isComplete` verifies you didn't miss one.
public enum ProviderRegistry {
    public static let all: [ProviderDescriptor] = MockProviders.descriptors

    private static let byID: [UsageProvider: ProviderDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func descriptor(for id: UsageProvider) -> ProviderDescriptor {
        guard let descriptor = byID[id] else {
            preconditionFailure("Missing ProviderDescriptor for \(id.rawValue)")
        }
        return descriptor
    }

    /// Every enum case must have a descriptor. Assert this at startup.
    public static var isComplete: Bool {
        UsageProvider.allCases.allSatisfy { byID[$0] != nil }
    }
}
