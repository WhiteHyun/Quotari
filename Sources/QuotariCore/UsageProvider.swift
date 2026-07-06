import Foundation

/// Demo/mock providers. Replace with real ones as fetch strategies are added.
public enum UsageProvider: String, CaseIterable, Sendable, Codable, Identifiable {
    case codex
    case claude
    case glm

    public var id: String { rawValue }
}
