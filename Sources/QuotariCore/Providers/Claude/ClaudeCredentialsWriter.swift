import Foundation

public protocol ClaudeCredentialPersisting: Sendable {
  /// Persists a refreshed token pair, but only if the source still holds
  /// `previousAccessToken` — a different token means someone re-logged-in or
  /// rotated behind our back, and overwriting would clobber the newer pair.
  func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws
}

public enum ClaudeCredentialPersistError: LocalizedError, Sendable {
  case sourceUnavailable
  case malformedPayload
  case staleSource
  case keychainWriteFailed(status: Int32)

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable: "The credential source can't be written to."
    case .malformedPayload: "The stored credentials payload is malformed."
    case .staleSource: "The credential source changed since the refresh started."
    case let .keychainWriteFailed(status): "Writing the keychain item failed (security exited \(status))."
    }
  }
}

/// Writes a refreshed token pair back to the source Claude Code reads from,
/// so both apps keep using the same (possibly rotated) refresh token. Only the
/// token fields inside `claudeAiOauth` change — everything else in the payload
/// (`mcpOAuth`, plan metadata, unknown future keys) is semantically preserved.
public struct ClaudeCredentialsWriter: ClaudeCredentialPersisting {
  private let keychainRead: @Sendable (String) -> Data?
  private let keychainWrite: @Sendable (Data, String) throws -> Void
  private let capturedAccounts: CapturedAccountStore

  public init(
    keychainRead: (@Sendable (String) -> Data?)? = nil,
    keychainWrite: (@Sendable (Data, String) throws -> Void)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore()
  ) {
    self.keychainRead = keychainRead ?? { ClaudeCredentialsStore.keychainItem(service: $0) }
    self.keychainWrite = keychainWrite ?? Self.writeKeychainItem
    self.capturedAccounts = capturedAccounts
  }

  public func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws {
    switch source {
    case .claudeEnvironment:
      return // env tokens are static; nothing to write back
    case let .claudeCredentialsFile(path):
      let url = URL(fileURLWithPath: path)
      let merged = try merge(grant, replacing: previousAccessToken, into: Data(contentsOf: url))
      try merged.write(to: url, options: [.atomic])
      // The atomic replacement file must not widen the credentials' access.
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    case let .claudeKeychain(service):
      guard let data = keychainRead(service) else { throw ClaudeCredentialPersistError.sourceUnavailable }
      try keychainWrite(merge(grant, replacing: previousAccessToken, into: data), service)
    case let .quotariRegistry(id):
      // A captured account Quotari owns: refresh keeps the stored snapshot's
      // token alive so the account stays usable while it's not the live one.
      // The merge runs inside updatePayload's mutation lock so the stale-token
      // guard is atomic with the write — a concurrent re-capture can't be
      // clobbered by a merge based on the pair it just replaced.
      guard capturedAccounts.account(id: id) != nil else {
        throw ClaudeCredentialPersistError.sourceUnavailable
      }
      try capturedAccounts.updatePayload(id: id) { payload in
        try merge(grant, replacing: previousAccessToken, into: payload)
      }
    case .codexAuthFile:
      throw ClaudeCredentialPersistError.sourceUnavailable
    }
  }

  func merge(_ grant: ClaudeTokenGrant, replacing previousAccessToken: String, into data: Data) throws -> Data {
    guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var oauth = root["claudeAiOauth"] as? [String: Any]
    else { throw ClaudeCredentialPersistError.malformedPayload }
    guard oauth["accessToken"] as? String == previousAccessToken else {
      throw ClaudeCredentialPersistError.staleSource
    }
    oauth["accessToken"] = grant.accessToken
    if let refreshToken = grant.refreshToken {
      oauth["refreshToken"] = refreshToken
    }
    if let expiresAt = grant.expiresAt {
      oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
    } else {
      // Keeping the old expiry would make the next load refresh immediately
      // while the in-memory pair reports no expiry; drop it so both agree.
      oauth.removeValue(forKey: "expiresAt")
    }
    if let scopes = grant.scopes {
      // The server's scope answer is authoritative; requesting stale scopes
      // on the next refresh would fail once the grant narrows.
      oauth["scopes"] = scopes
    }
    root["claudeAiOauth"] = oauth
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }

  /// Writes through the `security` CLI for the same reason reads do: the
  /// keychain ACL consent sticks to the stable system binary instead of
  /// re-prompting for every rebuilt dev binary. The command is fed through
  /// stdin (`security -i`) so the credential payload never appears in argv.
  private static func writeKeychainItem(_ data: Data, service: String) throws {
    guard let payload = String(data: data, encoding: .utf8) else {
      throw ClaudeCredentialPersistError.malformedPayload
    }
    let command = [
      "add-generic-password",
      "-U",
      "-a", quoted(NSUserName()),
      "-s", quoted(service),
      "-w", quoted(payload),
    ].joined(separator: " ") + "\n"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["-i"]
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    stdin.fileHandleForWriting.write(Data(command.utf8))
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ClaudeCredentialPersistError.keychainWriteFailed(status: process.terminationStatus)
    }
  }

  /// Quotes a token for the `security -i` command parser: backslash-escaped
  /// backslashes and double quotes inside double quotes.
  private static func quoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
