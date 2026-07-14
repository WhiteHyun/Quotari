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
    guard let credentials = try? CodexCredentialsStore.parse(data),
          let fields = CodexJSONProjector.topLevelFields(data),
          let tokens = fields["tokens"]
    else { throw CodexCredentialPersistError.malformedPayload }
    guard credentials.accessToken == previousAccessToken else {
      throw CodexCredentialPersistError.staleSource
    }
    var tokenReplacements = try ["access_token": JSONEncoder().encode(grant.accessToken)]
    if let refreshToken = grant.refreshToken {
      tokenReplacements["refresh_token"] = try JSONEncoder().encode(refreshToken)
    }
    if let idToken = grant.idToken {
      tokenReplacements["id_token"] = try JSONEncoder().encode(idToken)
    }
    guard let mergedTokens = CodexJSONProjector.replacingTopLevelFields(
      in: tokens, with: tokenReplacements
    ) else { throw CodexCredentialPersistError.malformedPayload }
    var rootReplacements = ["tokens": mergedTokens]
    if let refreshedAt = grant.refreshedAt {
      rootReplacements["last_refresh"] = try JSONEncoder().encode(
        ISO8601DateFormatter().string(from: refreshedAt)
      )
    }
    guard let merged = CodexJSONProjector.replacingTopLevelFields(
      in: data, with: rootReplacements
    ) else { throw CodexCredentialPersistError.malformedPayload }
    return merged
  }
}
