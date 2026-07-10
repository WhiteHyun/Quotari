import Foundation

/// OAuth credentials for the Claude Code CLI, carrying the plan metadata the
/// usage endpoint itself doesn't report.
public struct ClaudeCredentials: Equatable, Sendable {
  public var accessToken: String
  public var subscriptionType: String?
  public var rateLimitTier: String?

  public init(accessToken: String, subscriptionType: String? = nil, rateLimitTier: String? = nil) {
    self.accessToken = accessToken
    self.subscriptionType = subscriptionType
    self.rateLimitTier = rateLimitTier
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
    if let token = environment[tokenEnvKey], !token.isEmpty {
      return ClaudeCredentials(accessToken: token)
    }
    if let data = keychainItem(),
       let credentials = try? parse(data) {
      return credentials
    }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    if let data = try? Data(contentsOf: fileURL) {
      return try parse(data)
    }
    throw ClaudeCredentialsError.notFound
  }

  public static func load(
    source: ProviderCredentialSource,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> ClaudeCredentials {
    switch source {
    case let .claudeEnvironment(name):
      guard let token = environment[name], !token.isEmpty else { throw ClaudeCredentialsError.notFound }
      return ClaudeCredentials(accessToken: token)
    case .claudeKeychain:
      guard let data = keychainItem() else { throw ClaudeCredentialsError.notFound }
      return try parse(data)
    case let .claudeCredentialsFile(path):
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      return try parse(data)
    case .codexAuthFile:
      throw ClaudeCredentialsError.notFound
    }
  }

  static func parse(_ data: Data) throws -> ClaudeCredentials {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let accessToken = oauth["accessToken"] as? String,
          !accessToken.isEmpty
    else { throw ClaudeCredentialsError.malformed }
    return ClaudeCredentials(
      accessToken: accessToken,
      subscriptionType: oauth["subscriptionType"] as? String,
      rateLimitTier: oauth["rateLimitTier"] as? String
    )
  }

  /// Reads the keychain item through the `security` CLI rather than
  /// Security.framework: the ACL consent then sticks to the stable system
  /// binary, so rebuilt dev binaries don't re-prompt on every run.
  static func keychainItem() -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
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
