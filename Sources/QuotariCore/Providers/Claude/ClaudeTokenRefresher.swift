import Foundation

/// A refreshed token pair as returned by the OAuth token endpoint.
public struct ClaudeTokenGrant: Codable, Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date?
  public var scopes: [String]?

  public init(
    accessToken: String,
    refreshToken: String? = nil,
    expiresAt: Date? = nil,
    scopes: [String]? = nil
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.scopes = scopes
  }
}

public protocol ClaudeTokenRefreshing: Sendable {
  func refresh(refreshToken: String, scopes: [String], now: Date) async throws -> ClaudeTokenGrant
}

public enum ClaudeTokenRefreshError: LocalizedError, Sendable {
  case malformedResponse

  public var errorDescription: String? {
    switch self {
    case .malformedResponse: "The OAuth token endpoint returned an unexpected payload."
    }
  }
}

/// Exchanges Claude Code's refresh token for a fresh access token, mirroring
/// the request the CLI itself sends (verified against Claude Code 2.1.207:
/// JSON body with `grant_type`, `refresh_token`, `client_id`, and `scope`).
public struct ClaudeTokenRefresher: ClaudeTokenRefreshing {
  public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

  /// Claude Code's public OAuth client identifier (no secret; PKCE client).
  public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  /// The scopes Claude Code requests when the stored credential has none.
  public static let defaultScopes = [
    "user:profile",
    "user:inference",
    "user:sessions:claude_code",
    "user:mcp_servers",
    "user:file_upload",
  ]

  private let transport: any ProviderHTTPTransport
  private let tokenURL: URL

  public init(
    transport: any ProviderHTTPTransport = URLSession.shared,
    tokenURL: URL = ClaudeTokenRefresher.tokenURL
  ) {
    self.transport = transport
    self.tokenURL = tokenURL
  }

  public func refresh(refreshToken: String, scopes: [String], now: Date) async throws -> ClaudeTokenGrant {
    let scope = (scopes.isEmpty ? Self.defaultScopes : scopes).joined(separator: " ")
    let body = try JSONSerialization.data(withJSONObject: [
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": Self.clientID,
      "scope": scope,
    ])
    let data = try await transport.postJSON(url: tokenURL, body: body)
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accessToken = root["access_token"] as? String,
          !accessToken.isEmpty
    else { throw ClaudeTokenRefreshError.malformedResponse }
    let rotated = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return ClaudeTokenGrant(
      accessToken: accessToken,
      refreshToken: rotated,
      expiresAt: (root["expires_in"] as? Double).map { now.addingTimeInterval($0) },
      scopes: (root["scope"] as? String).flatMap { scope in
        let scopes = scope.split(separator: " ").map(String.init)
        return scopes.isEmpty ? nil : scopes
      }
    )
  }
}

/// A grant the OAuth endpoint already issued whose write-back failed. Kept
/// with the access token the merge expected (so a retry still detects a
/// source that has moved on) and the refresh token the exchange consumed (so
/// a stored pair still riding that token is recognized as superseded by this
/// grant rather than exchanged again).
public struct ClaudePendingGrant: Codable, Equatable, Sendable {
  public var grant: ClaudeTokenGrant
  public var previousAccessToken: String
  public var consumedRefreshToken: String
  /// Older source generations that can be repaired directly to `grant`.
  /// These are populated when a file mirror misses more than one canonical
  /// keychain rotation (A -> B -> C). Optional fields keep payloads written by
  /// older Quotari versions source-compatible with synthesized Codable.
  public var priorAccessTokens: [String]?
  public var priorConsumedRefreshTokens: [String]?
  /// Set only after an account switch durably captures the resolved live
  /// generation. If cleanup later fails, an unmatched record is then harmless
  /// cleanup debt rather than the only remaining copy of a valid grant.
  public var liveSourceBackupRecorded: Bool?

  public init(
    grant: ClaudeTokenGrant,
    previousAccessToken: String,
    consumedRefreshToken: String,
    priorAccessTokens: [String]? = nil,
    priorConsumedRefreshTokens: [String]? = nil,
    liveSourceBackupRecorded: Bool? = nil
  ) {
    self.grant = grant
    self.previousAccessToken = previousAccessToken
    self.consumedRefreshToken = consumedRefreshToken
    self.priorAccessTokens = priorAccessTokens
    self.priorConsumedRefreshTokens = priorConsumedRefreshTokens
    self.liveSourceBackupRecorded = liveSourceBackupRecorded
  }

  /// Whether the exchange demonstrably rotated the refresh token. Only then
  /// is the consumed token known dead — a grant that returned no token (or
  /// the same one) proves the endpoint keeps it alive across exchanges.
  public var rotatedRefreshToken: Bool {
    grant.refreshToken.map { $0 != consumedRefreshToken } ?? false
  }

  func matchesInstalledGeneration(accessToken: String, refreshToken: String?) -> Bool {
    accessToken == grant.accessToken
      && refreshToken == (grant.refreshToken ?? consumedRefreshToken)
  }

  /// Whether this grant supersedes the generation currently stored in a
  /// credential source. Refresh-token lineage is usable only when the final
  /// grant actually rotates away from that exact token.
  func supersedes(accessToken: String, refreshToken: String?) -> Bool {
    if accessToken == previousAccessToken || (priorAccessTokens ?? []).contains(accessToken) {
      return true
    }
    guard let refreshToken,
          refreshToken == consumedRefreshToken
          || (priorConsumedRefreshTokens ?? []).contains(refreshToken),
          let rotatedRefreshToken = grant.refreshToken,
          rotatedRefreshToken != refreshToken
    else { return false }
    return true
  }

  /// Collapses an older A -> B recovery into this B -> C recovery. The
  /// resulting journal can repair either the stale A mirror or the canonical
  /// B source directly to C, so every crash point around the two writes keeps
  /// a usable final grant.
  func chaining(after predecessor: ClaudePendingGrant) -> ClaudePendingGrant? {
    guard predecessor.grant.accessToken == previousAccessToken
      || (predecessor.grant.refreshToken != nil
        && predecessor.grant.refreshToken == consumedRefreshToken)
    else { return nil }
    var chained = self
    chained.priorAccessTokens = Self.lineage(
      primary: previousAccessToken,
      values: (priorAccessTokens ?? [])
        + [predecessor.previousAccessToken]
        + (predecessor.priorAccessTokens ?? [])
    )
    chained.priorConsumedRefreshTokens = Self.lineage(
      primary: consumedRefreshToken,
      values: (priorConsumedRefreshTokens ?? [])
        + [predecessor.consumedRefreshToken]
        + (predecessor.priorConsumedRefreshTokens ?? [])
    )
    // The final C generation has not been backed up merely because A -> B
    // was. A composed journal always starts as unbacked recovery work.
    chained.liveSourceBackupRecorded = nil
    return chained
  }

  /// Combines two recovery records that protect the same final grant. This
  /// occurs when a retry is rebased to the canonical source while the mirror
  /// journal still carries older generations that can reach that same grant.
  func mergingLineage(with other: ClaudePendingGrant) -> ClaudePendingGrant? {
    guard grant == other.grant else { return nil }
    var merged = self
    merged.priorAccessTokens = Self.lineage(
      primary: previousAccessToken,
      values: (priorAccessTokens ?? [])
        + [other.previousAccessToken]
        + (other.priorAccessTokens ?? [])
    )
    merged.priorConsumedRefreshTokens = Self.lineage(
      primary: consumedRefreshToken,
      values: (priorConsumedRefreshTokens ?? [])
        + [other.consumedRefreshToken]
        + (other.priorConsumedRefreshTokens ?? [])
    )
    // If either owner still needs recovery, the combined record is unbacked.
    merged.liveSourceBackupRecorded = liveSourceBackupRecorded == true
      && other.liveSourceBackupRecorded == true ? true : nil
    return merged
  }

  /// Re-targets a guarded retry to the exact source access token while
  /// retaining every older generation that the durable journal can repair.
  func rebased(replacing accessToken: String) -> ClaudePendingGrant {
    var rebased = self
    rebased.previousAccessToken = accessToken
    rebased.priorAccessTokens = Self.lineage(
      primary: accessToken,
      values: [previousAccessToken] + (priorAccessTokens ?? [])
    )
    rebased.liveSourceBackupRecorded = nil
    return rebased
  }

  private static func lineage(primary: String, values: [String]) -> [String]? {
    var seen = Set([primary])
    let unique = values.filter { seen.insert($0).inserted }
    return unique.isEmpty ? nil : unique
  }
}

/// Runs the whole refresh-and-persist transaction once per key: Quotari can
/// fetch the same provider from more than one place at once (dashboard
/// refresh + account popover), and burning the rotating refresh token twice
/// would invalidate the pair the first caller just obtained. The key includes
/// the refresh-token generation, so a caller that already holds a newer pair
/// never joins (or clobbers) an older generation's transaction.
///
/// Also holds grants whose registry write-back failed: the exchange already
/// consumed the stored refresh token server-side, so losing the new pair
/// could strand a saved account — the next transaction retries the write
/// instead of submitting the burned token again. Only registry sources are
/// queued; the CLI-owned keychain/file have Claude Code as a co-owner that
/// recovers them with its own refresh.
/// The shared transaction's credential result plus proof that this process
/// successfully installed a specific grant into the live CLI source. Every
/// caller receives the proof, including callers that joined an in-flight
/// refresh, so each can mirror it to its own verified saved-account link.
public struct ClaudeRefreshResolution: Sendable {
  public var resolved: ResolvedClaudeCredentials
  public var acceptedGrant: ClaudePendingGrant?

  public init(
    resolved: ResolvedClaudeCredentials,
    acceptedGrant: ClaudePendingGrant? = nil
  ) {
    self.resolved = resolved
    self.acceptedGrant = acceptedGrant
  }
}

public actor ClaudeTokenRefreshCoordinator {
  public static let shared = ClaudeTokenRefreshCoordinator()

  private struct AcceptedLiveGeneration: Sendable {
    var accessToken: String
    var refreshToken: String?
    var pending: ClaudePendingGrant
  }

  private var inFlight: [String: Task<ClaudeRefreshResolution, Never>] = [:]
  private var unpersisted: [String: ClaudePendingGrant] = [:]
  private var acceptedBySource: [String: [AcceptedLiveGeneration]] = [:]

  public init() {}

  public func resolve(
    key: String,
    operation: @escaping @Sendable () async -> ClaudeRefreshResolution
  ) async -> ClaudeRefreshResolution {
    if let task = inFlight[key] {
      return await task.value
    }
    let task = Task { Self.validated(await operation()) }
    inFlight[key] = task
    defer { inFlight[key] = nil }
    let resolution = await task.value
    if let accepted = resolution.acceptedGrant {
      let sourceID = resolution.resolved.source.stableID
      let generation = AcceptedLiveGeneration(
        accessToken: resolution.resolved.credentials.accessToken,
        refreshToken: resolution.resolved.credentials.refreshToken,
        pending: accepted
      )
      var recent = acceptedBySource[sourceID, default: []]
      recent.removeAll {
        $0.accessToken == generation.accessToken
          && $0.refreshToken == generation.refreshToken
      }
      recent.append(generation)
      acceptedBySource[sourceID] = Array(recent.suffix(4))
    }
    return resolution
  }

  private static func validated(_ resolution: ClaudeRefreshResolution) -> ClaudeRefreshResolution {
    guard let accepted = resolution.acceptedGrant,
          !accepted.matchesInstalledGeneration(
            accessToken: resolution.resolved.credentials.accessToken,
            refreshToken: resolution.resolved.credentials.refreshToken
          )
    else { return resolution }
    var sanitized = resolution
    sanitized.acceptedGrant = nil
    return sanitized
  }

  /// Returns proof retained from a completed transaction. This covers a
  /// linked account fetch that starts just after an unlinked caller completed
  /// the shared refresh: its token is already fresh, so it would otherwise
  /// skip the coordinator and never mirror the accepted grant.
  public func acceptedGrant(
    sourceID: String,
    accessToken: String,
    refreshToken: String?
  ) -> ClaudePendingGrant? {
    acceptedBySource[sourceID]?.last {
      $0.accessToken == accessToken && $0.refreshToken == refreshToken
    }?.pending
  }

  public func rememberUnpersisted(_ pending: ClaudePendingGrant, sourceID: String) {
    unpersisted[sourceID] = pending
  }

  public func takeUnpersisted(sourceID: String) -> ClaudePendingGrant? {
    unpersisted.removeValue(forKey: sourceID)
  }
}
