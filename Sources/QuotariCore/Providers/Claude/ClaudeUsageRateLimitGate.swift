import Foundation

/// Persists the Claude usage endpoint's cooldown so background refreshes do
/// not repeatedly hit Anthropic after a 429. User-initiated fetches bypass the
/// read gate, but a successful response still clears the shared cooldown.
public actor ClaudeUsageRateLimitGate {
  public enum Persistence: Sendable {
    case standard
    case suite(String)
  }

  public static let shared = ClaudeUsageRateLimitGate(persistence: .standard)

  private static let blockedUntilKey = "claudeOAuthUsageRateLimitBlockedUntilV1"

  private let persistence: Persistence?
  private let defaultCooldown: TimeInterval
  private let currentDate: @Sendable () -> Date
  private var inMemoryBlockedUntil: Date?

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

  public func blockedUntil(now: Date? = nil) -> Date? {
    let now = now ?? currentDate()
    guard let blockedUntil = storedBlockedUntil else { return nil }
    guard blockedUntil > now else {
      clear()
      return nil
    }
    return blockedUntil
  }

  public func recordRateLimit(retryAfter: Date?, now: Date? = nil) {
    let now = now ?? currentDate()
    let blockedUntil = if let retryAfter, retryAfter > now {
      retryAfter
    } else {
      now.addingTimeInterval(defaultCooldown)
    }
    store(blockedUntil)
  }

  public func recordSuccess() {
    clear()
  }

  private var storedBlockedUntil: Date? {
    if let defaults = persistedDefaults {
      guard let raw = defaults.object(forKey: Self.blockedUntilKey) as? Double else {
        return nil
      }
      return Date(timeIntervalSince1970: raw)
    }
    return inMemoryBlockedUntil
  }

  private func store(_ blockedUntil: Date) {
    if let defaults = persistedDefaults {
      defaults.set(blockedUntil.timeIntervalSince1970, forKey: Self.blockedUntilKey)
    } else {
      inMemoryBlockedUntil = blockedUntil
    }
  }

  private func clear() {
    if let defaults = persistedDefaults {
      defaults.removeObject(forKey: Self.blockedUntilKey)
    } else {
      inMemoryBlockedUntil = nil
    }
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
