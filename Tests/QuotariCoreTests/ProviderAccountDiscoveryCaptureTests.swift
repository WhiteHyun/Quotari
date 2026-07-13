import Foundation
@testable import QuotariCore
import Testing

// Discovery reconciliation scenarios intentionally share one fixture suite.
// swiftlint:disable:next type_body_length
struct ProviderAccountDiscoveryCaptureTests {
  /// Writes a Codex `auth.json` inside a fresh CODEX_HOME dir and returns that
  /// dir, so discovery's `CODEX_HOME` lookup finds it.
  private func codexHome(accountID: String, token: String = "tok") throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let url = home.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)","refresh_token":"live-ref"}}"#.utf8)
      .write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return home
  }

  @Test func capturedAccountJoinsDiscoveryWhenNotLive() async throws {
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "Test-Disc-\(UUID().uuidString)")
    // A captured Codex account for an identity that is NOT the current login.
    try store.save(CapturedAccount(
      id: "codex:acct-saved",
      provider: .codex,
      displayName: "Saved Codex",
      detail: "Personal",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: "/tmp/old.json"),
      payload: Data(#"{"tokens":{"access_token":"saved","account_id":"acct-saved"}}"#.utf8)
    ))
    // No live credentials on this synthetic home / empty env.
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: store
    )

    let accounts = await discovery.accounts(for: .codex)

    #expect(accounts.count == 1)
    #expect(accounts.first?.credentialSource == .quotariRegistry(id: "codex:acct-saved"))
    #expect(accounts.first?.displayName == "Saved Codex")
  }

  @Test func capturedAccountIsHiddenWhenItsIdentityIsLive() async throws {
    let liveHome = try codexHome(accountID: "acct-1")
    defer { try? FileManager.default.removeItem(at: liveHome) }
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "Test-Disc-\(UUID().uuidString)")
    // Captured snapshot of the SAME identity that is currently the live login.
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Codex",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: liveHome.appendingPathComponent("auth.json").path),
      payload: Data(#"{"tokens":{"access_token":"tok","account_id":"acct-1"}}"#.utf8)
    ))
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": liveHome.path],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: store
    )

    let accounts = await discovery.accounts(for: .codex)

    // Only the live account, since the saved one shares its account_id.
    #expect(accounts.count == 1)
    #expect(accounts.allSatisfy { !$0.credentialSource.isCaptured })
  }

  @Test func hiddenSavedAccountResolvesToItsLiveEquivalent() async throws {
    let liveHome = try codexHome(accountID: "acct-1")
    defer { try? FileManager.default.removeItem(at: liveHome) }
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "Test-Disc-\(UUID().uuidString)")
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Codex",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: liveHome.appendingPathComponent("auth.json").path),
      payload: Data(#"{"tokens":{"access_token":"tok","account_id":"acct-1"}}"#.utf8)
    ))
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": liveHome.path],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: store
    )
    let accounts = await discovery.accounts(for: .codex)
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:acct-1")
    )

    let live = await discovery.liveAccount(equivalentTo: saved, among: accounts)

    #expect(live != nil)
    #expect(live?.credentialSource.isCaptured == false)
    #expect(live == accounts.first)
  }

  @Test func legacyIDLessSavedAccountMapsToTheLiveRefreshTokenIdentity() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let authURL = home.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"live-token","refresh_token":"shared-refresh"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    defer { try? FileManager.default.removeItem(at: home) }

    let legacyID = "codex:550e8400-e29b-41d4-a716-446655440000"
    let store = CapturedAccountStore(
      keychain: InMemoryKeychain().store,
      service: "Test-Disc-\(UUID().uuidString)"
    )
    try store.save(CapturedAccount(
      id: legacyID,
      provider: .codex,
      displayName: "Legacy Codex",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: authURL.path),
      payload: Data(#"{"tokens":{"access_token":"saved-token","refresh_token":"shared-refresh"}}"#.utf8)
    ))
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": home.path],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: store
    )

    let accounts = await discovery.accounts(for: .codex)
    let live = try #require(accounts.first)
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Legacy Codex",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: legacyID)
    )

    #expect(accounts.count == 1)
    #expect(!live.credentialSource.isCaptured)
    #expect(await discovery.liveAccount(equivalentTo: saved, among: accounts) == live)
    let capturedCopies = await discovery.capturedCopies(among: accounts)
    #expect(capturedCopies[live.id]?.credentialSource == .quotariRegistry(id: legacyID))
  }

  @Test func savedAccountWithADifferentIdentityHasNoLiveEquivalent() async throws {
    let liveHome = try codexHome(accountID: "acct-live")
    defer { try? FileManager.default.removeItem(at: liveHome) }
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "Test-Disc-\(UUID().uuidString)")
    try store.save(CapturedAccount(
      id: "codex:acct-saved",
      provider: .codex,
      displayName: "Saved Codex",
      detail: "Personal",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: "/tmp/old.json"),
      payload: Data(#"{"tokens":{"access_token":"saved","account_id":"acct-saved"}}"#.utf8)
    ))
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": liveHome.path],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: store
    )
    let accounts = await discovery.accounts(for: .codex)
    let saved = accounts.first { $0.credentialSource.isCaptured }

    let live = try await discovery.liveAccount(equivalentTo: #require(saved), among: accounts)

    #expect(live == nil)
  }

  @Test func liveAccountsWithSavedCopiesAreReported() async throws {
    let liveHome = try codexHome(accountID: "acct-1")
    defer { try? FileManager.default.removeItem(at: liveHome) }
    let keychain = InMemoryKeychain()
    let store = CapturedAccountStore(keychain: keychain.store, service: "Test-Disc-\(UUID().uuidString)")
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Codex",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: liveHome.appendingPathComponent("auth.json").path),
      payload: Data(#"{"tokens":{"access_token":"tok","account_id":"acct-1"}}"#.utf8)
    ))
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": liveHome.path],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: store
    )
    let accounts = await discovery.accounts(for: .codex)

    let saved = await discovery.capturedCopies(among: accounts)

    #expect(Set(saved.keys) == Set(accounts.map(\.id)))
    #expect(saved.values.first?.credentialSource == .quotariRegistry(id: "codex:acct-1"))

    // A different captured identity flags nothing.
    let otherStore = CapturedAccountStore(keychain: InMemoryKeychain().store, service: "Test-Disc-\(UUID().uuidString)")
    try otherStore.save(CapturedAccount(
      id: "codex:acct-other",
      provider: .codex,
      displayName: "Other",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: "/tmp/old.json"),
      payload: Data(#"{"tokens":{"access_token":"x","account_id":"acct-other"}}"#.utf8)
    ))
    let otherDiscovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": liveHome.path],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: otherStore
    )
    #expect(await otherDiscovery.capturedCopies(among: accounts) == [:])
  }

  @Test func anUnrenewableLiveLoginDoesNotHideTheSavedCopy() async throws {
    // The live slot parses (same account_id) but has no refresh token, so it
    // can't renew itself — the saved copy that can must stay visible.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let url = home.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"tok","account_id":"acct-1"}}"#.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    defer { try? FileManager.default.removeItem(at: home) }
    let store = CapturedAccountStore(keychain: InMemoryKeychain().store, service: "Test-Disc-\(UUID().uuidString)")
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Codex",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .codexAuthFile(path: url.path),
      payload: Data(#"{"tokens":{"access_token":"tok","account_id":"acct-1","refresh_token":"ref"}}"#.utf8)
    ))
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": home.path],
      home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      keychainData: { nil },
      capturedAccounts: store
    )

    let accounts = await discovery.accounts(for: .codex)

    #expect(accounts.contains { $0.credentialSource.isCaptured })
    #expect(await discovery.capturedCopies(among: accounts) == [:])
  }

  @Test func liveAccountPrefersTheCodexHomeSlotOverTheDefault() async throws {
    // Same account_id in both the default auth.json and CODEX_HOME/auth.json.
    // The effective CLI slot is CODEX_HOME, so reconciling a saved selection
    // must resolve to that row (not the default the CLI doesn't read).
    let defaultHome = try codexHome(accountID: "acct-1", token: "default-tok")
    let codexHomeDir = try codexHome(accountID: "acct-1", token: "codexhome-tok")
    defer {
      try? FileManager.default.removeItem(at: defaultHome)
      try? FileManager.default.removeItem(at: codexHomeDir)
    }
    let store = CapturedAccountStore(keychain: InMemoryKeychain().store, service: "Test-Disc-\(UUID().uuidString)")
    let discovery = ProviderAccountDiscovery(
      environment: ["CODEX_HOME": codexHomeDir.path],
      home: defaultHome, // default auth.json at <home>/.codex/auth.json
      keychainData: { nil },
      capturedAccounts: store
    )
    // Move the default file to where `home` expects it.
    let dotCodex = defaultHome.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: dotCodex, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: defaultHome.appendingPathComponent("auth.json"),
      to: dotCodex.appendingPathComponent("auth.json")
    )
    let accounts = await discovery.accounts(for: .codex)
    let savedCopy = ProviderAccount(
      provider: .codex, displayName: "Codex", detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:acct-1")
    )
    try store.save(CapturedAccount(
      id: "codex:acct-1", provider: .codex, displayName: "Codex", detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: codexHomeDir.appendingPathComponent("auth.json").path),
      payload: Data(#"{"tokens":{"access_token":"t","account_id":"acct-1","refresh_token":"r"}}"#.utf8)
    ))

    let resolved = await discovery.liveAccount(equivalentTo: savedCopy, among: accounts)

    #expect(resolved?.credentialSource == .codexAuthFile(path: codexHomeDir.appendingPathComponent("auth.json").path))
  }

  @Test func liveClaudeStoresWithTheSameLoginCollapseToOneRow() async throws {
    // The keychain and the credentials file mirror one login (same refresh
    // token, e.g. after a switch). Listing both would let their per-account
    // refreshes rotate the shared token concurrently and consume it — so
    // discovery collapses them to the canonical keychain row.
    let payload = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"shared-ref","expiresAt":9999999999999}}"#
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
    let dotClaude = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: dotClaude, withIntermediateDirectories: true)
    try Data(payload.utf8).write(to: dotClaude.appendingPathComponent(".credentials.json"))
    defer { try? FileManager.default.removeItem(at: home) }
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: home,
      keychainData: { Data(payload.utf8) },
      capturedAccounts: CapturedAccountStore(keychain: InMemoryKeychain().store, service: "Test-\(UUID().uuidString)")
    )

    let accounts = await discovery.accounts(for: .claude)

    #expect(accounts.count == 1)
    #expect(accounts.first?.credentialSource == .claudeKeychain(service: "Claude Code-credentials"))
  }
}
