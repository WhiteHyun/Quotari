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
    // path. A captured entry is hidden when its identity matches a RENEWABLE
    // live login — an unrenewable live payload (no refresh token) must not
    // hide the saved copy that can still refresh itself.
    let liveIdentities = Set(live.compactMap { renewableIdentity(of: $0.credentialSource, provider: provider) })
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
    // Prefer the canonical source when more than one live row shares the
    // identity: for Claude the keychain (what Claude Code and `loadResolved`
    // read first) over the credentials file; for Codex the *effective* slot
    // (`CODEX_HOME` over the default) — a refresh of the selected account must
    // rotate the store the CLI actually reads.
    return accounts
      .filter { !$0.credentialSource.isCaptured
        && identity(of: $0.credentialSource, provider: $0.provider) == key
      }
      .min { sourceRank($0.credentialSource) < sourceRank($1.credentialSource) }
  }

  private func sourceRank(_ source: ProviderCredentialSource) -> Int {
    switch source {
    case .claudeKeychain: 0
    case let .codexAuthFile(path): path == effectiveCodexSlotPath ? 0 : 1
    case .claudeCredentialsFile: 2
    case .claudeEnvironment: 3
    case .quotariRegistry: 4
    }
  }

  /// The `auth.json` path the Codex CLI actually reads: `CODEX_HOME` over the
  /// default. Nil when neither is resolvable.
  private var effectiveCodexSlotPath: String? {
    let url: URL = if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
      URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
    } else {
      CodexCredentialsStore.defaultURL(home: home)
    }
    return url.standardizedFileURL.path
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
      guard let key = renewableIdentity(of: account.credentialSource, provider: account.provider),
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
    rawPayload(of: source).flatMap { ProviderCredentialIdentity.key(provider: provider, payload: $0) }
  }

  /// The identity of a live login, but only when its payload can renew
  /// itself (carries a refresh token) — the bar for standing in for a saved
  /// copy, hiding it, or feeding a sync.
  private func renewableIdentity(of source: ProviderCredentialSource, provider: UsageProvider) -> String? {
    guard let payload = rawPayload(of: source),
          ProviderCredentialMinimizer.minimize(provider: provider, payload: payload) != nil
    else { return nil }
    return ProviderCredentialIdentity.key(provider: provider, payload: payload)
  }

  private func rawPayload(of source: ProviderCredentialSource) -> Data? {
    switch source {
    case let .codexAuthFile(path), let .claudeCredentialsFile(path):
      try? Data(contentsOf: URL(fileURLWithPath: path))
    case .claudeKeychain:
      keychainData()
    case .claudeEnvironment, .quotariRegistry:
      nil
    }
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
          credentialIdentity: credentials.accountID
            ?? credentials.email
            ?? credentials.refreshToken
            ?? credentials.accessToken
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
    // Collapse stores that hold the SAME login (keychain + credentials file
    // after a switch mirror one login, sharing a refresh token). Listing both
    // would let their per-account refreshes rotate that shared token
    // concurrently and consume it out from under each other; keep the first
    // (env, then keychain — the canonical store the CLI reads before the file).
    return accounts.deduplicated(on: { identity(of: $0.credentialSource, provider: .claude) ?? $0.id })
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
