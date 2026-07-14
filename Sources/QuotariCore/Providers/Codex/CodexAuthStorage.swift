import CryptoKit
import Foundation
import TOML

enum CodexAuthCredentialsStoreMode: String, Equatable, Sendable {
  case file
  case keyring
  case auto
}

enum CodexKeyringReadState: Equatable, Sendable {
  case notChecked
  case available
  case missing
  case unavailable
}

struct CodexAuthSnapshot: Equatable, Sendable {
  var mode: CodexAuthCredentialsStoreMode
  var source: ProviderCredentialSource
  var payload: Data?
  var keyringState: CodexKeyringReadState
}

enum CodexAuthStorageError: LocalizedError, Sendable {
  case invalidConfiguration
  case unsupportedMode(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "Codex's cli_auth_credentials_store setting is malformed."
    case let .unsupportedMode(mode):
      "Codex credential storage mode '\(mode)' isn't supported by Quotari."
    }
  }
}

/// Resolves the credential backend Codex actually reads. Codex scopes its
/// macOS keychain item by a SHA-256 digest of the effective CODEX_HOME, so
/// separate homes keep independent logins just as file storage does.
struct CodexAuthStorage: Sendable {
  static let keychainService = "Codex Auth"

  let environment: [String: String]
  let home: URL
  let keychainRead: @Sendable (String, String) throws -> Data?

  var codexHome: URL {
    if let configured = environment["CODEX_HOME"], !configured.isEmpty {
      return URL(fileURLWithPath: configured).standardizedFileURL
    }
    return home.appendingPathComponent(".codex").standardizedFileURL
  }

  var authFileURL: URL {
    codexHome.appendingPathComponent("auth.json")
  }

  var keychainAccount: String {
    let resolved = codexHome.resolvingSymlinksInPath().standardizedFileURL.path
    let digest = SHA256.hash(data: Data(resolved.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "cli|\(digest.prefix(16))"
  }

  var keychainSource: ProviderCredentialSource {
    .codexKeychain(service: Self.keychainService, account: keychainAccount)
  }

  func configuredMode() throws -> CodexAuthCredentialsStoreMode {
    let url = codexHome.appendingPathComponent("config.toml")
    guard FileManager.default.fileExists(atPath: url.path) else { return .file }
    let contents: String
    do {
      contents = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw CodexAuthStorageError.invalidConfiguration
    }
    let configuration = try Self.parseConfiguration(contents)
    let mode = try Self.mode(from: configuration)
    if mode != .file, configuration.usesEncryptedSecretBackend {
      // Codex 0.144 keeps this backend disabled by default on macOS. When a
      // user explicitly enables it, the `Codex Auth` item contains an
      // encryption key rather than auth.json bytes; fail closed instead of
      // corrupting that store or pretending a switch succeeded.
      throw CodexAuthStorageError.unsupportedMode("encrypted keyring")
    }
    return mode
  }

  func snapshot() throws -> CodexAuthSnapshot {
    let mode = try configuredMode()
    switch mode {
    case .file:
      return try CodexAuthSnapshot(
        mode: mode,
        source: .codexAuthFile(path: authFileURL.path),
        payload: readSecureFile(authFileURL),
        keyringState: .notChecked
      )
    case .keyring:
      let payload = try keychainRead(Self.keychainService, keychainAccount)
      if let payload, !Self.isValidAuthDocument(payload) {
        throw CodexCredentialsError.malformed
      }
      return CodexAuthSnapshot(
        mode: mode,
        source: keychainSource,
        payload: payload,
        keyringState: payload == nil ? .missing : .available
      )
    case .auto:
      do {
        if let payload = try keychainRead(Self.keychainService, keychainAccount) {
          guard Self.isValidAuthDocument(payload) else {
            return try autoFileSnapshot(keyringState: .unavailable)
          }
          return CodexAuthSnapshot(
            mode: mode,
            source: keychainSource,
            payload: payload,
            keyringState: .available
          )
        }
        return try autoFileSnapshot(keyringState: .missing)
      } catch {
        // Match Codex auto-mode loading: a keyring access failure falls back
        // to auth.json. The state remains part of the snapshot so switching
        // never overwrites an unreadable keyring item on a later write.
        return try autoFileSnapshot(keyringState: .unavailable)
      }
    }
  }

  func payload(for source: ProviderCredentialSource) throws -> Data? {
    switch source {
    case let .codexAuthFile(path):
      try readSecureFile(URL(fileURLWithPath: path))
    case let .codexKeychain(service, account):
      try keychainRead(service, account)
    case .claudeEnvironment, .claudeKeychain, .claudeCredentialsFile, .quotariRegistry:
      nil
    }
  }

  private func autoFileSnapshot(keyringState: CodexKeyringReadState) throws -> CodexAuthSnapshot {
    try CodexAuthSnapshot(
      mode: .auto,
      source: .codexAuthFile(path: authFileURL.path),
      payload: readSecureFile(authFileURL),
      keyringState: keyringState
    )
  }

  private func readSecureFile(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    if let posix = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber,
       posix.intValue & 0o077 != 0 {
      throw CodexCredentialsError.insecurePermissions
    }
    return try Data(contentsOf: url)
  }

  static func parseMode(_ contents: String) throws -> CodexAuthCredentialsStoreMode {
    try mode(from: parseConfiguration(contents))
  }

  static func canRemoveFallback(_ payload: Data) -> Bool {
    guard let fields = CodexJSONProjector.topLevelFields(payload) else {
      return false
    }
    let oauthRootKeys: Set = ["auth_mode", "last_refresh", "tokens"]
    return Set(fields.keys).isSubset(of: oauthRootKeys)
  }

  private static func mode(
    from configuration: CodexConfigDocument
  ) throws -> CodexAuthCredentialsStoreMode {
    guard let value = configuration.cliAuthCredentialsStore else { return .file }
    guard let mode = CodexAuthCredentialsStoreMode(rawValue: value) else {
      throw CodexAuthStorageError.unsupportedMode(value)
    }
    return mode
  }

  private static func parseConfiguration(_ contents: String) throws -> CodexConfigDocument {
    do {
      return try TOMLDecoder().decode(CodexConfigDocument.self, from: contents)
    } catch {
      throw CodexAuthStorageError.invalidConfiguration
    }
  }

  private static func isValidAuthDocument(_ payload: Data) -> Bool {
    var duplicateKeyValidator = CodexJSONDuplicateKeyValidator(payload)
    guard duplicateKeyValidator.validate(),
          let projectedPayload = CodexJSONProjector.project(payload, schema: .authDocument)
    else { return false }
    return (try? JSONDecoder().decode(CodexAuthDocument.self, from: projectedPayload)) != nil
  }
}

private struct CodexConfigDocument: Decodable {
  let cliAuthCredentialsStore: String?
  let profile: String?
  let features: CodexFeatureConfiguration?
  let profiles: [String: CodexProfileConfiguration]?

  enum CodingKeys: String, CodingKey {
    case cliAuthCredentialsStore = "cli_auth_credentials_store"
    case profile
    case features
    case profiles
  }

  var usesEncryptedSecretBackend: Bool {
    if let profile, let override = profiles?[profile]?.features?.secretAuthStorage {
      return override
    }
    return features?.secretAuthStorage ?? false
  }
}

private struct CodexProfileConfiguration: Decodable {
  let features: CodexFeatureConfiguration?
}

private struct CodexFeatureConfiguration: Decodable {
  let secretAuthStorage: Bool?

  enum CodingKeys: String, CodingKey {
    case secretAuthStorage = "secret_auth_storage"
  }
}
