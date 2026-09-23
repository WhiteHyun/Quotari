import Foundation
@testable import Quotari
@testable import QuotariCore

enum AutomaticCLIRecoverySelection {
  case saved, live, mirror

  func prepareStore(
    home: URL,
    saved: CapturedAccount,
    livePayload: Data,
    token: String
  ) throws -> ProviderAccountSelectionStore {
    let fileURL = home.appendingPathComponent(".claude/.credentials.json")
    if self == .mirror {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try livePayload.write(to: fileURL)
    }
    let store = ProviderAccountSelectionStore(url: home.appendingPathComponent("selection.json"))
    let selected = self == .saved ? saved.providerAccount : ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: nil,
      credentialSource: self == .mirror ? .claudeCredentialsFile(path: fileURL.path) : saved.origin,
      credentialIdentity: token
    )
    try store.save([.claude: selected])
    return store
  }
}

@MainActor
struct AutomaticCLIRecoveryAppFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let saved: CapturedAccount
  let slot: AutomaticCapturePayloadBox
  let keychain = AutomaticCLIRecoveryKeychain()
  let activity = AutomaticCLIRecoveryActivity()
  let now = Date()
  let source = ProviderCredentialSource.claudeKeychain(service: ClaudeCredentialsStore.keychainService)
  let store: UsageStore

  var liveID: String {
    ProviderAccount.id(provider: .claude, source: source)
  }

  var fileURL: URL {
    directory.url.appendingPathComponent(".claude/.credentials.json")
  }

  init(
    empty: Bool = false,
    selection: AutomaticCLIRecoverySelection = .saved,
    selectedToken: String = "old-access"
  ) throws {
    directory = try TemporaryDirectory()
    let home = directory.url
    registry = keychain.makeRegistry()
    slot = AutomaticCapturePayloadBox(empty ? Data(#"{"claudeAiOauth":{}}"#.utf8) : claudePayload(
      accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(-3600)
    ))
    let profile = ClaudeProfile(accountID: "account", email: "same@example.com", organizationID: "organization")
    saved = recoverySavedAccount(source: source, now: now, profile: profile)
    try registry.save(saved)
    try Data(#"{"oauthAccount":{"accountUuid":"account","organizationUuid":"organization"}}"#.utf8)
      .write(to: home.appendingPathComponent(".claude.json"))
    let selections = try selection.prepareStore(home: home, saved: saved, livePayload: slot.value, token: selectedToken)
    let profiles = try recoveryProfiles(home: home, saved: saved, profile: profile)
    let (registry, slot, activity, now, keychain) = (registry, slot, activity, now, keychain)
    store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: ProviderAccountDiscovery(
        environment: [:],
        home: home,
        keychainData: { try? keychain.readCLI(slot) },
        capturedAccounts: registry
      ),
      accountSelectionStore: selections,
      accountCapture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      automaticallyCapturesDiscoveredAccounts: true,
      accountSwitch: recoverySwitcher(
        registry: registry,
        home: home,
        slot: slot,
        activity: activity,
        keychain: keychain
      ),
      profileFetcher: TokenClaudeProfileFetcher(profiles: ["saved-access": profile, "old-access": profile]),
      profileStore: profiles,
      claudeCredentialLoader: { source in
        if case let .claudeCredentialsFile(path) = source {
          return (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? ClaudeCredentialsStore.parse($0) }
        }
        return automaticCaptureClaudeCredentials(
          source: source,
          keychainPayload: try? keychain.readCLI(slot),
          registry: registry
        )
      },
      currentDate: { now },
      startsAutomatically: false
    )
  }
}

private func recoveryProfiles(home: URL, saved: CapturedAccount, profile: ClaudeProfile) throws -> ClaudeProfileStore {
  let store = ClaudeProfileStore(url: home.appendingPathComponent("profiles.json"))
  try store.save([
    ProviderAccount.id(provider: .claude, source: saved.origin): profile.verified(
      for: ProviderCredentialIdentity.fingerprint(of: "old-access")
    ),
    saved.providerAccount.id: profile.verified(for: ProviderCredentialIdentity.fingerprint(of: "saved-access")),
  ])
  return store
}

private func recoverySavedAccount(
  source: ProviderCredentialSource,
  now: Date,
  profile: ClaudeProfile
) -> CapturedAccount {
  CapturedAccount(
    id: "claude:saved", provider: .claude, displayName: "Saved", detail: nil,
    capturedAt: now, origin: source,
    payload: claudePayload(
      accessToken: "saved-access", refreshToken: "saved-refresh", expiresAt: now.addingTimeInterval(3600)
    ),
    claudeAccountIdentity: profile.accountIdentity
  )
}

private func recoverySwitcher(
  registry: CapturedAccountStore,
  home: URL,
  slot: AutomaticCapturePayloadBox,
  activity: AutomaticCLIRecoveryActivity,
  keychain: AutomaticCLIRecoveryKeychain
) -> AccountSwitchService {
  AccountSwitchService(
    capturedAccounts: registry, environment: [:], home: home,
    keychainRead: { _ in try keychain.readCLI(slot) },
    keychainWrite: { data, _ in
      slot.value = data
      if activity.startsAfterCredentialWrite {
        activity.isActive = true
      }
    },
    keychainDelete: { _ in slot.value = Data(#"{"claudeAiOauth":{}}"#.utf8) },
    activeCLIProcesses: { _ in activity.isActive ? ["claude"] : [] }
  )
}

final class AutomaticCLIRecoveryKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var locked = false
  private var items: [String: Data] = [:]

  var isLocked: Bool {
    get { lock.withLock { locked } }
    set { lock.withLock { locked = newValue } }
  }

  func readCLI(_ slot: AutomaticCapturePayloadBox) throws -> Data {
    try lock.withLock {
      guard !locked else { throw CocoaError(.fileReadNoPermission) }
      return slot.value
    }
  }

  func makeRegistry() -> CapturedAccountStore {
    let keychain = KeychainItemStore(
      read: { service in
        try self.lock.withLock {
          guard !self.locked else { throw CocoaError(.fileReadNoPermission) }
          return self.items[service]
        }
      },
      write: { data, service in self.lock.withLock { self.items[service] = data } },
      delete: { service in _ = self.lock.withLock { self.items.removeValue(forKey: service) } }
    )
    return CapturedAccountStore(keychain: keychain, service: "Test-Recovery-\(UUID().uuidString)")
  }
}

final class AutomaticCLIRecoveryActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var startsAfterWrite = false

  var startsAfterCredentialWrite: Bool {
    get { lock.withLock { startsAfterWrite } }
    set { lock.withLock { startsAfterWrite = newValue } }
  }

  var isActive: Bool {
    get { lock.withLock { active } }
    set { lock.withLock { active = newValue } }
  }
}
