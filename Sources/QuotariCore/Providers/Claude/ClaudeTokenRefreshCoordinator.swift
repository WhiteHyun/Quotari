import Foundation

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
  /// Transaction keys (source + refresh-token generation) the token endpoint
  /// answered with `invalid_grant`. That token can never be exchanged again,
  /// so later fetches fail fast instead of re-submitting it every cycle; a
  /// relogin or an external rotation changes the generation and the key.
  private var rejectedGenerations: Set<String> = []

  public init() {}

  /// Keys whose transaction the current task is already running.
  @TaskLocal private static var heldKeys: Set<String> = []

  public func resolve(
    key: String,
    operation: @escaping @Sendable () async -> ClaudeRefreshResolution
  ) async -> ClaudeRefreshResolution {
    // A transaction can re-resolve its own source generation (an obsolete
    // pending grant over an expired pair). It already owns the key, so run
    // inline — awaiting the in-flight task would wait on itself forever.
    if Self.heldKeys.contains(key) {
      return await Self.validated(operation())
    }
    if let task = inFlight[key] {
      return await task.value
    }
    let held = Self.heldKeys.union([key])
    let task = Task {
      await Self.$heldKeys.withValue(held) {
        await Self.validated(operation())
      }
    }
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

  public func isRejected(key: String) -> Bool {
    rejectedGenerations.contains(key)
  }

  public func markRejected(key: String) {
    rejectedGenerations.insert(key)
  }

  /// Reads a queued grant without claiming it: the source that owns the
  /// grant still has to retry its own write.
  public func peekUnpersisted(sourceID: String) -> ClaudePendingGrant? {
    unpersisted[sourceID]
  }

  public func rememberUnpersisted(_ pending: ClaudePendingGrant, sourceID: String) {
    unpersisted[sourceID] = pending
  }

  public func takeUnpersisted(sourceID: String) -> ClaudePendingGrant? {
    unpersisted.removeValue(forKey: sourceID)
  }
}
