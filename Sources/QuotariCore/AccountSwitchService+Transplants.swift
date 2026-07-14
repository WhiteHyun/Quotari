import Foundation

extension AccountSwitchService {
  /// The saved account's whole `claudeAiOauth` object replaces the live one;
  /// the live payload's OTHER root keys (`mcpOAuth`, unknown future keys)
  /// survive. An empty slot yields just the saved credential.
  static func transplantClaude(saved: Data, intoLive live: Data?) throws -> Data {
    guard let savedRoot = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
          let oauth = savedRoot["claudeAiOauth"] as? [String: Any]
    else { throw ClaudeCredentialPersistError.malformedPayload }
    var root = live.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    root["claudeAiOauth"] = oauth
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }

  /// Same rule for Codex: the saved `tokens` object replaces the live one,
  /// while unrelated root siblings stay — but the auth mode is forced to the
  /// ChatGPT login the tokens represent. `last_refresh` belongs to the token
  /// generation, so it follows the saved account instead of the live account.
  /// Legacy saved rows without that metadata receive an intentionally stale
  /// timestamp: current Codex requires the field to load tokens, and staleness
  /// makes it refresh rather than trusting another account's refresh time.
  /// Without forcing the mode, switching from an API-key `auth.json` would
  /// leave `auth_mode: apikey` in place and
  /// Codex would keep using the API key instead of the switched-in account.
  /// `OPENAI_API_KEY` is preserved (not deleted): `auth_mode: chatgpt` already
  /// makes Codex use the tokens, and deleting the key would permanently lose
  /// an API-key login the backup path can't snapshot (it has no `tokens`).
  static func transplantCodex(saved: Data, intoLive live: Data?) throws -> Data {
    guard let credentials = try? CodexCredentialsStore.parse(saved),
          credentials.refreshToken != nil,
          let savedFields = CodexJSONProjector.topLevelFields(saved),
          let tokens = savedFields["tokens"]
    else { throw CodexCredentialPersistError.malformedPayload }
    let savedRefresh = savedFields["last_refresh"]
      .flatMap { try? JSONDecoder().decode(String.self, from: $0) }
      .flatMap { $0.isEmpty ? nil : $0 }
    let replacements = try [
      "tokens": tokens,
      "auth_mode": JSONEncoder().encode("chatgpt"),
      "last_refresh": JSONEncoder().encode(savedRefresh ?? "1970-01-01T00:00:00Z"),
    ]
    guard let merged = CodexJSONProjector.replacingTopLevelFields(
      in: live ?? Data("{}".utf8), with: replacements
    ) else { throw CodexCredentialPersistError.malformedPayload }
    return merged
  }
}
