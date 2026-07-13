import Foundation

public protocol ProviderAccountDiscovering: Sendable {
  func accounts(for provider: UsageProvider) async -> [ProviderAccount]

  /// The live account among `accounts` holding the same underlying credential
  /// identity as the given saved (registry) account, if any. Lets a selection
  /// pointing at a saved copy be reconciled to the live login that hides it.
  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount?

  /// The saved (registry) accounts standing behind the given live logins,
  /// keyed by live-account id — i.e. identities that are saved, with the
  /// saved row hidden while it is the live credential.
  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount]
}

public extension ProviderAccountDiscovering {
  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    nil
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    [:]
  }
}

public struct ProviderAccountDiscovery: ProviderAccountDiscovering {
  private let environment: [String: String]
  private let home: URL
  private let keychainData: @Sendable () -> Data?
  private let capturedAccounts: CapturedAccountStore

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    keychainData: (@Sendable () -> Data?)? = nil,
    capturedAccounts: CapturedAccountStore = CapturedAccountStore()
  ) {
    self.environment = environment
    self.home = home
    self.keychainData = keychainData ?? { ClaudeCredentialsStore.keychainItem() }
    self.capturedAccounts = capturedAccounts
  }

  public func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    let live = switch provider {
    case .codex: codexAccounts()
    case .claude: claudeAccounts()
    }
    // Captured snapshots join discovery so selection and usage reuse the same
    // path. A captured entry is hidden when its identity matches a live login,
    // so the same account isn't listed twice while it's the CLI credential.
    let liveIdentities = Set(live.compactMap { identity(of: $0.credentialSource, provider: provider) })
    let saved = capturedAccounts.load()
      .filter { $0.provider == provider }
      .filter { captured in
        guard let key = ProviderCredentialIdentity.key(provider: provider, payload: captured.payload)
        else { return true }
        return !liveIdentities.contains(key)
      }
      .map { captured in
        ProviderAccount(
          provider: provider,
          displayName: captured.displayName,
          detail: captured.detail ?? "Saved in Quotari",
          credentialSource: .quotariRegistry(id: captured.id)
        )
      }
    return live + saved
  }

  public func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    guard case let .quotariRegistry(id) = account.credentialSource,
          let captured = capturedAccounts.account(id: id),
          let key = ProviderCredentialIdentity.key(provider: captured.provider, payload: captured.payload)
    else { return nil }
    return accounts.first { candidate in
      !candidate.credentialSource.isCaptured
        && identity(of: candidate.credentialSource, provider: candidate.provider) == key
    }
  }

  public func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    let captured = capturedAccounts.load()
    guard !captured.isEmpty else { return [:] }
    let byIdentity: [UsageProvider: [String: CapturedAccount]] = captured
      .reduce(into: [:]) { keys, item in
        if let key = ProviderCredentialIdentity.key(provider: item.provider, payload: item.payload) {
          keys[item.provider, default: [:]][key] = item
        }
      }
    var copies: [String: ProviderAccount] = [:]
    for account in accounts where !account.credentialSource.isCaptured {
      guard let key = identity(of: account.credentialSource, provider: account.provider),
            let item = byIdentity[account.provider]?[key] else { continue }
      copies[account.id] = ProviderAccount(
        provider: item.provider,
        displayName: item.displayName,
        detail: item.detail ?? "Saved in Quotari",
        credentialSource: .quotariRegistry(id: item.id)
      )
    }
    return copies
  }

  private func identity(of source: ProviderCredentialSource, provider: UsageProvider) -> String? {
    let payload: Data? = switch source {
    case let .codexAuthFile(path), let .claudeCredentialsFile(path):
      try? Data(contentsOf: URL(fileURLWithPath: path))
    case .claudeKeychain:
      keychainData()
    case .claudeEnvironment, .quotariRegistry:
      nil
    }
    return payload.flatMap { ProviderCredentialIdentity.key(provider: provider, payload: $0) }
  }

  private func codexAccounts() -> [ProviderAccount] {
    let defaultURL = CodexCredentialsStore.defaultURL(home: home)
    var candidates: [(URL, String)] = [(defaultURL, "Default")]
    if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      let url = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
      candidates.append((url, "CODEX_HOME"))
    }

    return candidates
      .deduplicated(on: \.0.standardizedFileURL.path)
      .compactMap { url, label in
        guard let credentials = try? CodexCredentialsStore.load(url: url) else { return nil }
        let source = ProviderCredentialSource.codexAuthFile(path: url.standardizedFileURL.path)
        return ProviderAccount(
          provider: .codex,
          displayName: credentials.email ?? credentials.accountID ?? "Codex account",
          detail: label,
          credentialSource: source,
          credentialIdentity: credentials.accountID ?? credentials.accessToken
        )
      }
  }

  private func claudeAccounts() -> [ProviderAccount] {
    var accounts: [ProviderAccount] = []
    if let token = environment[ClaudeCredentialsStore.tokenEnvKey], !token.isEmpty {
      accounts.append(ProviderAccount(
        provider: .claude,
        displayName: "Claude OAuth token",
        detail: ClaudeCredentialsStore.tokenEnvKey,
        credentialSource: .claudeEnvironment(name: ClaudeCredentialsStore.tokenEnvKey),
        credentialIdentity: token
      ))
    }
    if let data = keychainData(),
       let credentials = try? ClaudeCredentialsStore.parse(data) {
      accounts.append(claudeAccount(
        credentials: credentials,
        displayName: "Claude Code",
        detail: "Keychain",
        source: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
      ))
    }
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    if let data = try? Data(contentsOf: fileURL),
       let credentials = try? ClaudeCredentialsStore.parse(data) {
      accounts.append(claudeAccount(
        credentials: credentials,
        displayName: "Claude Code",
        detail: "Credentials file",
        source: .claudeCredentialsFile(path: fileURL.standardizedFileURL.path)
      ))
    }
    return accounts.deduplicated(on: \.id)
  }

  private func claudeAccount(
    credentials: ClaudeCredentials,
    displayName: String,
    detail: String,
    source: ProviderCredentialSource
  ) -> ProviderAccount {
    ProviderAccount(
      provider: .claude,
      displayName: displayName,
      detail: detail,
      credentialSource: source,
      credentialIdentity: credentials.accessToken
    )
  }
}

private extension Sequence {
  func deduplicated<ID: Hashable>(on id: (Element) -> ID) -> [Element] {
    var seen: Set<ID> = []
    var values: [Element] = []
    for element in self where seen.insert(id(element)).inserted {
      values.append(element)
    }
    return values
  }
}
