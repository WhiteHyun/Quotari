import Foundation

public protocol ProviderAccountDiscovering: Sendable {
  func accounts(for provider: UsageProvider) async -> [ProviderAccount]
}

public struct ProviderAccountDiscovery: ProviderAccountDiscovering {
  private let environment: [String: String]
  private let home: URL
  private let keychainData: @Sendable () -> Data?

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    keychainData: (@Sendable () -> Data?)? = nil
  ) {
    self.environment = environment
    self.home = home
    self.keychainData = keychainData ?? { ClaudeCredentialsStore.keychainItem() }
  }

  public func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    switch provider {
    case .codex:
      codexAccounts()
    case .claude:
      claudeAccounts()
    case .glm:
      []
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
