import Foundation

/// OAuth credentials read from the Codex CLI's `~/.codex/auth.json`.
public struct CodexCredentials: Equatable, Sendable {
  public var accessToken: String
  public var accountID: String?
  public var email: String?
  public var refreshToken: String?
  public var expiresAt: Date?

  public init(
    accessToken: String,
    accountID: String?,
    email: String? = nil,
    refreshToken: String? = nil,
    expiresAt: Date? = nil
  ) {
    self.accessToken = accessToken
    self.accountID = accountID
    self.email = email
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }

  /// Whether the access token is past (or within `leeway` of) its expiry.
  /// Tokens whose JWT carries no `exp` claim never report expired — the
  /// API's 401 stays the arbiter for those.
  public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
    guard let expiresAt else { return false }
    return now >= expiresAt.addingTimeInterval(-leeway)
  }
}

public enum CodexCredentialsError: LocalizedError, Sendable {
  case notFound
  case insecurePermissions
  case malformed

  public var errorDescription: String? {
    switch self {
    case .notFound: "No Codex credentials found (~/.codex/auth.json)."
    case .insecurePermissions: "Codex credentials file is readable by others; refusing to use it."
    case .malformed: "Codex credentials file is malformed."
    }
  }
}

public enum CodexCredentialsStore {
  public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent(".codex/auth.json")
  }

  /// The credential file read by the Codex CLI: `CODEX_HOME` takes precedence
  /// over the default location when it is configured.
  public static func effectiveURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    guard let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty else {
      return defaultURL(home: home)
    }
    return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
  }

  /// Reads and validates the credential file. Rejects world/group-readable
  /// files defensively (the file holds a bearer token).
  public static func load(
    url: URL = defaultURL(),
    fileManager: FileManager = .default
  ) throws -> CodexCredentials {
    guard fileManager.fileExists(atPath: url.path) else { throw CodexCredentialsError.notFound }

    if let posix = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber,
       posix.intValue & 0o077 != 0 {
      throw CodexCredentialsError.insecurePermissions
    }

    let data = try Data(contentsOf: url)
    return try parse(data)
  }

  public static func load(
    source: ProviderCredentialSource,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore()
  ) throws -> CodexCredentials {
    switch source {
    case let .codexAuthFile(path):
      return try load(url: URL(fileURLWithPath: path))
    case let .quotariRegistry(id):
      guard let captured = capturedAccounts.account(id: id), captured.provider == .codex else {
        throw CodexCredentialsError.notFound
      }
      return try parse(captured.payload)
    case .claudeEnvironment, .claudeKeychain, .claudeCredentialsFile:
      throw CodexCredentialsError.notFound
    }
  }

  static func parse(_ data: Data) throws -> CodexCredentials {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any],
          let accessToken = tokens["access_token"] as? String,
          !accessToken.isEmpty
    else { throw CodexCredentialsError.malformed }
    return CodexCredentials(
      accessToken: accessToken,
      accountID: tokens["account_id"] as? String,
      email: (tokens["id_token"] as? String).flatMap(jwtEmail),
      refreshToken: (tokens["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      expiresAt: jwtExpiry(of: accessToken)
    )
  }

  /// The usage payload carries no account identity, but the OpenID `id_token`
  /// does. Claims are read unverified — display-only, never authorization.
  private static func jwtEmail(from token: String) -> String? {
    guard let claims = jwtClaims(of: token) else { return nil }
    let profile = claims["https://api.openai.com/profile"] as? [String: Any]
    let email = (claims["email"] as? String) ?? (profile?["email"] as? String)
    return email.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The access token's `exp` claim — `auth.json` stores no expiry of its
  /// own. Read unverified: it only decides when a saved account refreshes,
  /// never authorization.
  static func jwtExpiry(of token: String) -> Date? {
    (jwtClaims(of: token)?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
  }

  private static func jwtClaims(of token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 {
      payload.append("=")
    }
    guard let data = Data(base64Encoded: payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
