import Foundation

/// The single source of truth key for every provider the app knows about.
///
/// To add a provider: add a case here, then register a matching
/// `ProviderDescriptor` (see `ProviderRegistry`). `ProviderRegistry.isComplete`
/// asserts that no case is left without a descriptor.
///
/// NOTE: These are demo/mock providers. Replace them with real ones
/// (e.g. `claude`, `codex`, `cursor`, `copilot`) as you add real fetch
/// strategies.
public enum UsageProvider: String, CaseIterable, Sendable, Codable, Identifiable {
    case cortex
    case nimbus
    case loom

    public var id: String { rawValue }
}
