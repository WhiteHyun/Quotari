import Foundation

/// Persists the Claude usage endpoint's cooldown so background refreshes do
/// not repeatedly hit Anthropic after a 429. User-initiated fetches bypass the
/// read gate, but a successful response still clears that credential's cooldown.
public actor ClaudeUsageRateLimitGate {
  public enum Persistence: Sendable {
    case standard
    case suite(String)
  }

  public static let shared = ClaudeUsageRateLimitGate(persistence: .standard)

  private static let legacyBlockedUntilKey = "claudeOAuthUsageRateLimitBlockedUntilV1"
  private static let blockedUntilKeyPrefix = "claudeOAuthUsageRateLimitBlockedUntilV2."

  private let persistence: Persistence?
  private let defaultCooldown: TimeInterval
  private let currentDate: @Sendable () -> Date
  private var inMemoryBlockedUntil: [String: Date] = [:]

  /// Passing no persistence creates an isolated in-memory gate, useful for tests.
  public init(
    persistence: Persistence? = nil,
    defaultCooldown: TimeInterval = 5 * 60,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.persistence = persistence
    self.defaultCooldown = defaultCooldown
    currentDate = now
  }

  public func blockedUntil(
    for accessToken: String,
    now: Date? = nil
  ) -> Date? {
    let now = now ?? currentDate()
    let key = storageKey(for: accessToken)
    guard let blockedUntil = storedBlockedUntil(for: key) else { return nil }
    guard blockedUntil > now else {
      clear(key)
      return nil
    }
    return blockedUntil
  }

  public func recordRateLimit(
    for accessToken: String,
    retryAfter: Date?,
    now: Date? = nil
  ) {
    let now = now ?? currentDate()
    let key = storageKey(for: accessToken)
    if let retryAfter {
      guard retryAfter > now else {
        clear(key)
        return
      }
      store(max(storedBlockedUntil(for: key) ?? retryAfter, retryAfter), for: key)
      return
    }
    let fallback = now.addingTimeInterval(defaultCooldown)
    store(max(storedBlockedUntil(for: key) ?? fallback, fallback), for: key)
  }

  public func recordSuccess(for accessToken: String) {
    clear(storageKey(for: accessToken))
  }

  public func transferCooldown(
    from previousAccessToken: String,
    to currentAccessToken: String,
    now: Date? = nil
  ) {
    guard previousAccessToken != currentAccessToken else { return }
    let now = now ?? currentDate()
    let previousKey = storageKey(for: previousAccessToken)
    guard let deadline = storedBlockedUntil(for: previousKey), deadline > now else {
      clear(previousKey)
      return
    }
    let currentKey = storageKey(for: currentAccessToken)
    store(max(storedBlockedUntil(for: currentKey) ?? deadline, deadline), for: currentKey)
    clear(previousKey)
  }

  private func storedBlockedUntil(for key: String) -> Date? {
    if let defaults = persistedDefaults {
      defaults.removeObject(forKey: Self.legacyBlockedUntilKey)
      guard let raw = defaults.object(forKey: key) as? Double else {
        return nil
      }
      return Date(timeIntervalSince1970: raw)
    }
    return inMemoryBlockedUntil[key]
  }

  private func store(_ blockedUntil: Date, for key: String) {
    if let defaults = persistedDefaults {
      defaults.removeObject(forKey: Self.legacyBlockedUntilKey)
      defaults.set(blockedUntil.timeIntervalSince1970, forKey: key)
    } else {
      inMemoryBlockedUntil[key] = blockedUntil
    }
  }

  private func clear(_ key: String) {
    if let defaults = persistedDefaults {
      defaults.removeObject(forKey: Self.legacyBlockedUntilKey)
      defaults.removeObject(forKey: key)
    } else {
      inMemoryBlockedUntil[key] = nil
    }
  }

  private func storageKey(for accessToken: String) -> String {
    Self.blockedUntilKeyPrefix + ProviderCredentialIdentity.fingerprint(of: accessToken)
  }

  private var persistedDefaults: UserDefaults? {
    switch persistence {
    case .standard:
      UserDefaults.standard
    case let .suite(name):
      UserDefaults(suiteName: name)
    case nil:
      nil
    }
  }
}
