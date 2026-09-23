import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeAutomaticRecoveryTests {
  @Test func reloadRepairsTheCLIAndCollapsesTheSelectedSavedCopy() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture()

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    let accounts = try #require(fixture.store.accounts[.claude])
    #expect(accounts.count == 1)
    #expect(accounts.first?.credentialSource == fixture.source)
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == fixture.source)
    #expect(fixture.store.capturedEquivalents[fixture.liveID]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.registry.load().count == 1)
    #expect(!fixture.store.automaticallyCapturingProviders.contains(.claude))
  }

  @Test func periodicRefreshRepairsSavedOnlyMonitoringAfterClaudeExits() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(empty: true)
    fixture.activity.isActive = true
    await fixture.store.reloadAccounts()
    #expect(fixture.store.accounts[.claude]?.allSatisfy(\.credentialSource.isCaptured) == true)
    #expect(fixture.store.reconciledSelectionOrigins.isEmpty)
    #expect(fixture.store.activeCLIAccount(for: .claude) == nil)

    fixture.activity.isActive = false
    await fixture.store.refresh()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.activeCLIAccount(for: .claude)?.credentialSource == fixture.source)
    #expect(fixture.store.accounts[.claude]?.count == 1)
  }

  @Test(arguments: [false, true])
  func reloadKeepsTheSelectedLiveAccountAfterRecovery(selectMirror: Bool) async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: selectMirror ? .mirror : .live)
    let previousScope = try #require(fixture.store.selectedAccounts[.claude]?.credentialScopeID)
    #expect(fixture.store.reconciledSelectionOrigins[.claude] == nil)

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    let selected = try #require(fixture.store.selectedAccounts[.claude])
    #expect(selected.credentialSource == fixture.source)
    #expect(selected.credentialScopeID != previousScope)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.accounts[.claude]?.count == 1)
  }

  @Test func recoveryDoesNotAdoptASelectionForAnUnrelatedTokenInTheSameSlot() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .live, selectedToken: "unrelated-access")

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.selectedAccounts[.claude] == nil)
    #expect(fixture.store.reconciledSelectionOrigins[.claude] == nil)
  }

  @Test func recoveryContinuesTheCredentialTransitionCompletedBeforeReload() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .live, selectedToken: "earlier-access")
    let selectedScope = try #require(fixture.store.selectedAccounts[.claude]?.credentialScopeID)
    let live = ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: nil,
      credentialSource: fixture.source, credentialIdentity: "old-access"
    )
    fixture.store.completedCredentialTransitions[.claude] = [selectedScope: [live.credentialScopeID]]

    await fixture.store.reloadAccounts()

    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == fixture.source)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
  }

  @Test func automaticRecoveryNeverFollowsAnUnrelatedDashboardSelection() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture()
    let other = CapturedAccount(
      id: "claude:other", provider: .claude, displayName: "Other", detail: nil,
      capturedAt: fixture.now, origin: fixture.source,
      payload: claudePayload(
        accessToken: "other-access",
        refreshToken: "other-refresh",
        expiresAt: fixture.now.addingTimeInterval(3600)
      ),
      claudeAccountIdentity: ClaudeAccountIdentity(accountID: "other", organizationID: "other-org")
    )
    try fixture.registry.save(other)
    fixture.store.selectAccount(other.providerAccount, for: .claude)

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.selectedAccounts[.claude]?.id == other.providerAccount.id)
    #expect(fixture.registry.account(id: other.id) == other)
  }
}

private enum AutomaticCLIRecoverySelection {
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
private struct AutomaticCLIRecoveryAppFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let saved: CapturedAccount
  let slot: AutomaticCapturePayloadBox
  let activity = AutomaticCLIRecoveryActivity()
  let now = Date()
  let source = ProviderCredentialSource.claudeKeychain(service: ClaudeCredentialsStore.keychainService)
  let store: UsageStore

  var liveID: String {
    ProviderAccount.id(provider: .claude, source: source)
  }

  init(
    empty: Bool = false,
    selection: AutomaticCLIRecoverySelection = .saved,
    selectedToken: String = "old-access"
  ) throws {
    directory = try TemporaryDirectory()
    let home = directory.url
    registry = .inMemoryForTesting()
    slot = AutomaticCapturePayloadBox(empty ? Data(#"{"claudeAiOauth":{}}"#.utf8) : claudePayload(
      accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(-3600)
    ))
    let profile = ClaudeProfile(accountID: "account", email: "same@example.com", organizationID: "organization")
    saved = CapturedAccount(
      id: "claude:saved", provider: .claude, displayName: "Saved", detail: nil,
      capturedAt: now, origin: source,
      payload: claudePayload(
        accessToken: "saved-access",
        refreshToken: "saved-refresh",
        expiresAt: now.addingTimeInterval(3600)
      ),
      claudeAccountIdentity: profile.accountIdentity
    )
    try registry.save(saved)
    try Data(#"{"oauthAccount":{"accountUuid":"account","organizationUuid":"organization"}}"#.utf8)
      .write(to: home.appendingPathComponent(".claude.json"))
    let selections = try selection.prepareStore(home: home, saved: saved, livePayload: slot.value, token: selectedToken)
    let profiles = ClaudeProfileStore(url: home.appendingPathComponent("profiles.json"))
    try profiles.save([
      ProviderAccount.id(provider: .claude, source: source): profile.verified(
        for: ProviderCredentialIdentity.fingerprint(of: "old-access")
      ),
      saved.providerAccount.id: profile.verified(for: ProviderCredentialIdentity.fingerprint(of: "saved-access")),
    ])
    let (registry, slot, activity, now) = (registry, slot, activity, now)
    store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: ProviderAccountDiscovery(
        environment: [:],
        home: home,
        keychainData: { slot.value },
        capturedAccounts: registry
      ),
      accountSelectionStore: selections,
      accountCapture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in slot.value }),
      automaticallyCapturesDiscoveredAccounts: true,
      accountSwitch: recoverySwitcher(registry: registry, home: home, slot: slot, activity: activity),
      profileFetcher: TokenClaudeProfileFetcher(profiles: ["saved-access": profile, "old-access": profile]),
      profileStore: profiles,
      claudeCredentialLoader: { source in
        automaticCaptureClaudeCredentials(source: source, keychainPayload: slot.value, registry: registry)
      },
      currentDate: { now },
      startsAutomatically: false
    )
  }
}

private func recoverySwitcher(
  registry: CapturedAccountStore,
  home: URL,
  slot: AutomaticCapturePayloadBox,
  activity: AutomaticCLIRecoveryActivity
) -> AccountSwitchService {
  AccountSwitchService(
    capturedAccounts: registry, environment: [:], home: home,
    keychainRead: { _ in slot.value },
    keychainWrite: { data, _ in slot.value = data },
    keychainDelete: { _ in slot.value = Data(#"{"claudeAiOauth":{}}"#.utf8) },
    activeCLIProcesses: { _ in activity.isActive ? ["claude"] : [] }
  )
}

private final class AutomaticCLIRecoveryActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false

  var isActive: Bool {
    get { lock.withLock { active } }
    set { lock.withLock { active = newValue } }
  }
}
