import Foundation

/// Formats machine plan identifiers into marketing tier names.
/// Usage multipliers are shown only when explicitly present in the identifier;
/// a Codex Pro identifier alone does not establish a price or usage allowance.
public enum PlanLabel {
  private static let codexExactNames: [String: String] = [
    "pro": "Pro",
    "prolite": "Pro",
    "pro_lite": "Pro",
    "pro-lite": "Pro",
    "pro lite": "Pro",
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
