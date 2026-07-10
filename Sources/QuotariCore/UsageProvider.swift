import Foundation

/// Demo/mock providers. Replace with real ones as fetch strategies are added.
public enum UsageProvider: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
  case codex
  case claude

  public var id: String {
    rawValue
  }
}
