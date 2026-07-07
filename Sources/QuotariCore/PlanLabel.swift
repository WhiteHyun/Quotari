import Foundation

/// Formats machine plan identifiers ("pro_lite", "default_claude_max_20x")
/// into the marketing tier names, keeping the usage multiplier (5x/20x)
/// visible when the tier carries one.
public enum PlanLabel {
  private static let codexExactNames: [String: String] = [
    "pro": "Pro 20x",
    "prolite": "Pro 5x",
    "pro_lite": "Pro 5x",
    "pro-lite": "Pro 5x",
    "pro lite": "Pro 5x",
  ]

  private static let claudeBaseTiers = ["max", "pro", "team", "enterprise", "ultra", "free"]

  public static func codex(_ raw: String?) -> String? {
    guard let raw = trimmed(raw) else { return nil }
    if let exact = codexExactNames[raw.lowercased()] {
      return exact
    }
    let formatted = words(of: raw).map(capitalize).joined(separator: " ")
    return formatted.isEmpty ? raw : formatted
  }

  public static func claude(subscriptionType: String?, rateLimitTier: String?) -> String? {
    let subscriptionWords = words(of: trimmed(subscriptionType) ?? "")
    let tierWords = words(of: trimmed(rateLimitTier) ?? "")
    guard let base = claudeBaseTiers.first(where: subscriptionWords.contains)
      ?? claudeBaseTiers.first(where: tierWords.contains)
    else { return trimmed(subscriptionType) ?? trimmed(rateLimitTier) }

    let multiplier = (tierWords + subscriptionWords).first { word in
      word.count > 1 && word.hasSuffix("x") && word.dropLast().allSatisfy(\.isNumber)
    }
    let label = capitalize(base)
    return multiplier.map { "\(label) \($0)" } ?? label
  }

  private static func trimmed(_ value: String?) -> String? {
    let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (cleaned?.isEmpty ?? true) ? nil : cleaned
  }

  private static func words(of value: String) -> [String] {
    value.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  private static func capitalize(_ word: String) -> String {
    guard let first = word.first, first.isLowercase else { return word }
    return first.uppercased() + word.dropFirst()
  }
}
