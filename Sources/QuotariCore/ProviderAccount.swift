import Foundation

public struct ProviderAccount: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var provider: UsageProvider
  public var displayName: String
  public var detail: String?
  public var credentialSource: ProviderCredentialSource
  private var credentialFingerprint: String?

  public init(
    provider: UsageProvider,
    displayName: String,
    detail: String?,
    credentialSource: ProviderCredentialSource,
    credentialIdentity: String? = nil
  ) {
    self.provider = provider
    self.displayName = displayName
    self.detail = detail
    self.credentialSource = credentialSource
    credentialFingerprint = credentialIdentity.map(Self.fingerprint)
    id = Self.id(provider: provider, source: credentialSource)
  }

  public static func id(provider: UsageProvider, source: ProviderCredentialSource) -> String {
    "\(provider.rawValue):\(source.stableID)"
  }

  public var credentialScopeID: String {
    credentialFingerprint.map { "\(id):\($0)" } ?? id
  }

  var costCacheScopeID: String {
    credentialScopeID
  }

  private static func fingerprint(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}

public enum ProviderCredentialSource: Codable, Equatable, Sendable {
  case codexAuthFile(path: String)
  case claudeEnvironment(name: String)
  case claudeKeychain(service: String)
  case claudeCredentialsFile(path: String)
  /// A snapshot Quotari captured and owns, identified by its registry id.
  case quotariRegistry(id: String)

  public var stableID: String {
    switch self {
    case let .codexAuthFile(path):
      "codex-file:\(path)"
    case let .claudeEnvironment(name):
      "claude-env:\(name)"
    case let .claudeKeychain(service):
      "claude-keychain:\(service)"
    case let .claudeCredentialsFile(path):
      "claude-file:\(path)"
    case let .quotariRegistry(id):
      "quotari-registry:\(id)"
    }
  }

  public var detail: String {
    switch self {
    case .codexAuthFile:
      "auth.json"
    case let .claudeEnvironment(name):
      name
    case .claudeKeychain:
      "Keychain"
    case .claudeCredentialsFile:
      ".credentials.json"
    case .quotariRegistry:
      "Saved in Quotari"
    }
  }

  /// True for sources whose bytes Quotari itself owns and can rewrite.
  public var isCaptured: Bool {
    if case .quotariRegistry = self {
      return true
    }
    return false
  }

  /// Namespaces durable recovery data for a CLI-owned Claude credential
  /// source. Both the refresh and account-switch paths must derive this key
  /// identically so a rotated grant cannot be stranded beside the slot it
  /// protects.
  var claudeLivePendingGrantID: String? {
    switch self {
    case .claudeKeychain, .claudeCredentialsFile:
      "claude-live:\(ProviderCredentialIdentity.fingerprint(of: stableID))"
    case .codexAuthFile, .claudeEnvironment, .quotariRegistry:
      nil
    }
  }
}
