import Foundation

/// A refreshed Codex token set as returned by the OAuth token endpoint.
public struct CodexTokenGrant: Codable, Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  public var idToken: String?
  /// When Quotari received this grant. Saved `auth.json` snapshots carry the
  /// value as `last_refresh`, which Codex requires alongside ChatGPT tokens.
  public var refreshedAt: Date?

  public init(
    accessToken: String,
    refreshToken: String? = nil,
    idToken: String? = nil,
    refreshedAt: Date? = nil
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.refreshedAt = refreshedAt
  }
}

public protocol CodexTokenRefreshing: Sendable {
  func refresh(refreshToken: String) async throws -> CodexTokenGrant
}

public enum CodexTokenRefreshError: LocalizedError, Sendable {
  case malformedResponse

  public var errorDescription: String? {
    switch self {
    case .malformedResponse: "The OAuth token endpoint returned an unexpected payload."
    }
  }
}

/// Exchanges the Codex CLI's refresh token for a fresh access token, mirroring
/// the request the CLI itself sends (verified against codex-cli 0.144.1: JSON
/// body with `client_id`, `grant_type`, and `refresh_token`; no `scope` field,
/// so the grant keeps its originally issued scope per RFC 6749 §6).
public struct CodexTokenRefresher: CodexTokenRefreshing {
  public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

  /// The Codex CLI's public OAuth client identifier (no secret; PKCE client).
  public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

  private let transport: any ProviderHTTPTransport
  private let tokenURL: URL

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    tokenURL: URL = CodexTokenRefresher.tokenURL
  ) {
    self.transport = transport
    self.tokenURL = tokenURL
  }

  public func refresh(refreshToken: String) async throws -> CodexTokenGrant {
    let body = try JSONSerialization.data(withJSONObject: [
      "client_id": Self.clientID,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
    ])
    let data = try await transport.postJSON(url: tokenURL, body: body)
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accessToken = root["access_token"] as? String,
          !accessToken.isEmpty
    else { throw CodexTokenRefreshError.malformedResponse }
    return CodexTokenGrant(
      accessToken: accessToken,
      refreshToken: nonEmpty(root["refresh_token"]),
      idToken: nonEmpty(root["id_token"])
    )
  }

  private func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
  }
}

/// A grant the OAuth endpoint already issued whose write-back failed. Kept
/// with the access token the merge expected (so a retry still detects a
/// registry that has moved on) and the refresh token the exchange consumed
/// (so a stored pair still riding that token is recognized as superseded by
/// this grant rather than exchanged again).
public struct CodexPendingGrant: Codable, Equatable, Sendable {
  public var grant: CodexTokenGrant
  public var previousAccessToken: String
  public var consumedRefreshToken: String

  public init(grant: CodexTokenGrant, previousAccessToken: String, consumedRefreshToken: String) {
    self.grant = grant
    self.previousAccessToken = previousAccessToken
    self.consumedRefreshToken = consumedRefreshToken
  }

  /// Whether the exchange demonstrably rotated the refresh token. Only then
  /// is the consumed token known dead — a grant that returned no token (or
  /// the same one) proves the endpoint keeps it alive across exchanges.
  public var rotatedRefreshToken: Bool {
    grant.refreshToken.map { $0 != consumedRefreshToken } ?? false
  }
}

/// Runs the whole refresh-and-persist transaction once per key, for the same
/// reason as `ClaudeTokenRefreshCoordinator`: concurrent fetches of the same
/// saved account must not burn the rotating refresh token twice. The key
/// includes the refresh-token generation, so a caller that already holds a
/// newer pair never joins (or clobbers) an older generation's transaction.
///
/// Also holds grants whose persistence failed: the exchange already consumed
/// the stored refresh token server-side, so losing the new pair could strand
/// the saved account — the next transaction retries the write instead of
/// submitting the burned token again.
public actor CodexTokenRefreshCoordinator {
  public static let shared = CodexTokenRefreshCoordinator()

  private var inFlight: [String: Task<CodexCredentials, Never>] = [:]
  private var unpersisted: [String: CodexPendingGrant] = [:]

  public init() {}

  public func resolve(
    key: String,
    operation: @escaping @Sendable () async -> CodexCredentials
  ) async -> CodexCredentials {
    if let task = inFlight[key] {
      return await task.value
    }
    let task = Task { await operation() }
    inFlight[key] = task
    defer { inFlight[key] = nil }
    return await task.value
  }

  public func rememberUnpersisted(_ pending: CodexPendingGrant, registryID: String) {
    unpersisted[registryID] = pending
  }

  public func takeUnpersisted(registryID: String) -> CodexPendingGrant? {
    unpersisted.removeValue(forKey: registryID)
  }
}
