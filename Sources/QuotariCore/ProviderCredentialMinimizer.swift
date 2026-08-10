import Foundation

/// Reduces a raw provider credential payload to just the provider's own
/// credential object, dropping unrelated root-level secrets that live beside
/// it. Wrong-shaped, token-less, or refresh-token-less payloads are rejected:
/// an unrenewable snapshot would die at its first expiry.
public enum ProviderCredentialMinimizer {
  public static func minimize(provider: UsageProvider, payload: Data) -> Data? {
    switch provider {
    case .claude:
      guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty
      else { return nil }
      return try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    case .codex:
      guard let credentials = try? CodexCredentialsStore.parse(payload),
            credentials.refreshToken != nil,
            let fields = CodexJSONProjector.topLevelFields(payload),
            let tokens = fields["tokens"]
      else { return nil }
      var minimized = ["tokens": tokens]
      if let refreshData = fields["last_refresh"],
         let lastRefresh = try? JSONDecoder().decode(String.self, from: refreshData),
         !lastRefresh.isEmpty {
        minimized["last_refresh"] = refreshData
      }
      return CodexJSONProjector.replacingTopLevelFields(in: Data("{}".utf8), with: minimized)
    }
  }

  /// Whether the payload carries the provider's access token at all — used to
  /// distinguish an unreadable payload from a readable but unrenewable one.
  public static func hasAccessToken(provider: UsageProvider, payload: Data) -> Bool {
    switch provider {
    case .claude:
      guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
      else { return false }
      return !accessToken.isEmpty
    case .codex:
      return (try? CodexCredentialsStore.parse(payload)) != nil
    }
  }
}
