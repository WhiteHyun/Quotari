import Foundation

public protocol CodexCredentialPersisting: Sendable {
  /// Persists a refreshed token set to the saved account, but only if it
  /// still holds `previousAccessToken` — a different token means another
  /// refresh landed first, and overwriting would clobber the newer pair.
  func persist(
    _ grant: CodexTokenGrant,
    replacing previousAccessToken: String,
    toRegistryAccount id: String
  ) throws
}

public enum CodexCredentialPersistError: LocalizedError, Sendable {
  case sourceUnavailable
  case malformedPayload
  case staleSource

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable: "The saved account can't be written to."
    case .malformedPayload: "The saved credentials payload is malformed."
    case .staleSource: "The saved credentials changed since the refresh started."
    }
  }
}

/// Writes a refreshed Codex token set back to the captured account's registry
/// item. Only the token fields inside `tokens` change — everything else in the
/// payload (`account_id`, unknown future keys) is preserved. Saved accounts
/// are the only Codex source Quotari refreshes: the live `auth.json` is the
/// CLI's to manage, and racing its own refresh loop there could burn the
/// rotating token pair.
public struct CodexCredentialsWriter: CodexCredentialPersisting {
  private let capturedAccounts: CapturedAccountStore

  public init(capturedAccounts: CapturedAccountStore = CapturedAccountStore()) {
    self.capturedAccounts = capturedAccounts
  }

  public func persist(
    _ grant: CodexTokenGrant,
    replacing previousAccessToken: String,
    toRegistryAccount id: String
  ) throws {
    guard capturedAccounts.account(id: id) != nil else {
      throw CodexCredentialPersistError.sourceUnavailable
    }
    // The merge runs inside updatePayload's mutation lock so the stale-token
    // guard is atomic with the write — a concurrent re-capture can't be
    // clobbered by a merge based on the pair it just replaced.
    try capturedAccounts.updatePayload(id: id) { payload in
      try merge(grant, replacing: previousAccessToken, into: payload)
    }
  }

  func merge(_ grant: CodexTokenGrant, replacing previousAccessToken: String, into data: Data) throws -> Data {
    guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var tokens = root["tokens"] as? [String: Any]
    else { throw CodexCredentialPersistError.malformedPayload }
    guard tokens["access_token"] as? String == previousAccessToken else {
      throw CodexCredentialPersistError.staleSource
    }
    tokens["access_token"] = grant.accessToken
    if let refreshToken = grant.refreshToken {
      tokens["refresh_token"] = refreshToken
    }
    if let idToken = grant.idToken {
      tokens["id_token"] = idToken
    }
    root["tokens"] = tokens
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }
}
