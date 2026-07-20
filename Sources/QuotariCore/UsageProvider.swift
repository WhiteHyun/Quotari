import Foundation

/// Provider families supported by Quotari's live usage integrations.
public enum UsageProvider: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
  case codex
  case claude

  public var id: String {
    rawValue
  }
}
