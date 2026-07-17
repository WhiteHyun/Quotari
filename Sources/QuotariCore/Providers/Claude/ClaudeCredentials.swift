import Foundation

/// OAuth credentials for the Claude Code CLI, carrying the plan metadata the
/// usage endpoint itself doesn't report.
public struct ClaudeCredentials: Equatable, Sendable {
  public var accessToken: String
  public var refreshToken: String?
  public var expiresAt: Date?
  public var scopes: [String]
  public var subscriptionType: String?
  public var rateLimitTier: String?

  public init(
    accessToken: String,
    refreshToken: String? = nil,
    expiresAt: Date? = nil,
    scopes: [String] = [],
    subscriptionType: String? = nil,
    rateLimitTier: String? = nil
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.scopes = scopes
    self.subscriptionType = subscriptionType
    self.rateLimitTier = rateLimitTier
  }

  /// Whether the access token is past (or within `leeway` of) its expiry.
  /// Credentials without an expiry (e.g. env tokens) never report expired —
  /// the API's 401 stays the arbiter for those.
  public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
    guard let expiresAt else { return false }
    return now >= expiresAt.addingTimeInterval(-leeway)
  }
}

/// Credentials plus the concrete source they were read from, so a token
/// refresh knows where to persist the rotated pair.
public struct ResolvedClaudeCredentials: Equatable, Sendable {
  public var credentials: ClaudeCredentials
  public var source: ProviderCredentialSource

  public init(credentials: ClaudeCredentials, source: ProviderCredentialSource) {
    self.credentials = credentials
    self.source = source
  }
}

public enum ClaudeCredentialsError: LocalizedError, Sendable {
  case notFound
  case malformed

  public var errorDescription: String? {
    switch self {
    case .notFound: "No Claude credentials found (keychain or ~/.claude/.credentials.json)."
    case .malformed: "Claude credentials payload is malformed."
    }
  }
}

/// Discovers Claude Code's OAuth credentials: the `QUOTARI_CLAUDE_OAUTH_TOKEN`
/// environment variable wins, then the "Claude Code-credentials" keychain
/// item, then `~/.claude/.credentials.json`.
public enum ClaudeCredentialsStore {
  public static let tokenEnvKey = "QUOTARI_CLAUDE_OAUTH_TOKEN"
  public static let keychainService = "Claude Code-credentials"

  public static func load(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> ClaudeCredentials {
    try loadResolved(environment: environment, home: home).credentials
  }

  public static func loadResolved(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> ResolvedClaudeCredentials {
    if let token = environment[tokenEnvKey], !token.isEmpty {
      return ResolvedClaudeCredentials(
        credentials: ClaudeCredentials(accessToken: token),
        source: .claudeEnvironment(name: tokenEnvKey)
      )
    }
    if let data = keychainItem(),
       let credentials = try? parse(data) {
      return ResolvedClaudeCredentials(
        credentials: credentials,
        source: .claudeKeychain(service: keychainService)
      )
    }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    if let data = try? Data(contentsOf: fileURL) {
      return try ResolvedClaudeCredentials(
        credentials: parse(data),
        source: .claudeCredentialsFile(path: fileURL.standardizedFileURL.path)
      )
    }
    throw ClaudeCredentialsError.notFound
  }

  public static func load(
    source: ProviderCredentialSource,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore()
  ) throws -> ClaudeCredentials {
    switch source {
    case let .claudeEnvironment(name):
      guard let token = environment[name], !token.isEmpty else { throw ClaudeCredentialsError.notFound }
      return ClaudeCredentials(accessToken: token)
    case let .claudeKeychain(service):
      guard let data = keychainItem(service: service) else { throw ClaudeCredentialsError.notFound }
      return try parse(data)
    case let .claudeCredentialsFile(path):
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      return try parse(data)
    case let .quotariRegistry(id):
      guard let captured = capturedAccounts.account(id: id), captured.provider == .claude else {
        throw ClaudeCredentialsError.notFound
      }
      return try parse(captured.payload)
    case .codexAuthFile, .codexKeychain:
      throw ClaudeCredentialsError.notFound
    }
  }

  public static func parse(_ data: Data) throws -> ClaudeCredentials {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let accessToken = oauth["accessToken"] as? String,
          !accessToken.isEmpty
    else { throw ClaudeCredentialsError.malformed }
    return ClaudeCredentials(
      accessToken: accessToken,
      refreshToken: oauth["refreshToken"] as? String,
      expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
      scopes: oauth["scopes"] as? [String] ?? [],
      subscriptionType: oauth["subscriptionType"] as? String,
      rateLimitTier: oauth["rateLimitTier"] as? String
    )
  }

  /// Reads the keychain item through the `security` CLI rather than
  /// Security.framework: the ACL consent then sticks to the stable system
  /// binary, so rebuilt dev binaries don't re-prompt on every run.
  static func keychainItem(service: String = keychainService) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return nil
    }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    guard let text = String(data: output, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return nil }
    return Data(text.utf8)
  }
}
