import Foundation

/// OAuth credentials read from the Codex CLI's `~/.codex/auth.json`.
public struct CodexCredentials: Equatable, Sendable {
  public var accessToken: String
  public var accountID: String?
  public var email: String?

  public init(accessToken: String, accountID: String?, email: String? = nil) {
    self.accessToken = accessToken
    self.accountID = accountID
    self.email = email
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
      email: (tokens["id_token"] as? String).flatMap(jwtEmail)
    )
  }

  /// The usage payload carries no account identity, but the OpenID `id_token`
  /// does. Claims are read unverified — display-only, never authorization.
  private static func jwtEmail(from token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 {
      payload.append("=")
    }
    guard let data = Data(base64Encoded: payload),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let profile = claims["https://api.openai.com/profile"] as? [String: Any]
    let email = (claims["email"] as? String) ?? (profile?["email"] as? String)
    return email.flatMap { $0.isEmpty ? nil : $0 }
  }
}
