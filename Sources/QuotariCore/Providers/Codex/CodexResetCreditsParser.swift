import Foundation

/// Parses the Codex reset-credit list (`wham/rate-limit-reset-credits`) into the
/// expiry times of credits the user can still redeem, soonest first. Credits
/// without an expiry are left out because they never need a reminder.
public enum CodexResetCreditsParser {
  public static func parse(_ data: Data) throws -> [ResetCreditExpiry] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let credits = root["credits"] as? [[String: Any]]
    else { throw ProviderFetchError.noStrategyAvailable(.codex) }

    return credits.compactMap { credit -> ResetCreditExpiry? in
      guard credit["status"] as? String == "available",
            let id = credit["id"] as? String,
            let expiresAt = LenientDateParser.parse(credit["expires_at"])
      else { return nil }
      return ResetCreditExpiry(id: id, expiresAt: expiresAt)
    }
    .sorted { $0.expiresAt < $1.expiresAt }
  }
}
