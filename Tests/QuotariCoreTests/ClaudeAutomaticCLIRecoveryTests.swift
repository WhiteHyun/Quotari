import Foundation
@testable import QuotariCore
import Testing

struct ClaudeAutomaticCLIRecoveryTests {
  @Test func restoresExpiredLoginAndItsMirrorWithoutReplacingOtherFields() throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    let original = try #require(fixture.slot.value)
    try FileManager.default.createDirectory(
      at: fixture.fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try original.write(to: fixture.fileURL)
    var profiles = fixture.profiles
    profiles[ProviderAccount.id(provider: .claude, source: fixture.fileSource)] = fixture.profile.verified(
      for: ProviderCredentialIdentity.fingerprint(of: "old-access")
    )

    let result = try fixture.service().recoverClaudeCLIIfNeeded(profiles: profiles, now: fixture.now)

    #expect(result?.registryID == fixture.saved.id)
    #expect(result?.source == fixture.source)
    for payload in try [#require(fixture.slot.value), Data(contentsOf: fixture.fileURL)] {
      #expect(try ClaudeCredentialsStore.parse(payload).accessToken == "saved-access")
      let fields = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
      #expect(fields["other"] as? String == "preserved")
    }
    #expect(fixture.registry.load() == [fixture.saved])
    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: profiles, now: fixture.now) == nil)
  }

  @Test(arguments: [false, true])
  func restoresMissingOrEmptyTokenWhileTerminalIdentityRemains(missing: Bool) throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    fixture.slot
      .value = missing ? nil : Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#.utf8)

    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: [:], now: fixture.now) != nil)
    #expect(try ClaudeCredentialsStore.parse(#require(fixture.slot.value)).accessToken == "saved-access")
  }

  @Test func respectsLogoutWhenTerminalIdentityWasRemoved() throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    fixture.slot.value = nil
    try Data(#"{"theme":"dark"}"#.utf8).write(to: fixture.stateURL)

    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: fixture.profiles, now: fixture.now) == nil)
    #expect(fixture.slot.value == nil)
  }

  @Test(arguments: ["healthy", "unknown", "different-account", "different-organization", "corrupt", "refresh-only"])
  func refusesUnprovenOrHealthyCredentials(scenario: String) throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    var profiles = fixture.profiles
    switch scenario {
    case "healthy": fixture.slot.value = fixture.saved.payload
    case "unknown": profiles = [:]
    case "different-account": profiles[fixture.liveID]?.accountID = "other"
    case "different-organization": profiles[fixture.liveID]?.organizationID = "other"
    case "corrupt": fixture.slot.value = Data("corrupt".utf8)
    default: fixture.slot.value = Data(#"{"claudeAiOauth":{"refreshToken":"possibly-usable"}}"#.utf8)
    }
    let original = fixture.slot.value

    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: profiles, now: fixture.now) == nil)
    #expect(fixture.slot.value == original)
  }

  @Test(arguments: ["account", "organization", "email-only"])
  func refusesConflictingOrWeakTerminalIdentity(scenario: String) throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    var fields = ["accountUuid": "account", "organizationUuid": "organization", "emailAddress": "same@example.com"]
    if scenario == "email-only" {
      fields.removeValue(forKey: "accountUuid")
    }
    if scenario == "account" {
      fields["accountUuid"] = "different"
    }
    if scenario == "organization" {
      fields["organizationUuid"] = "different"
    }
    try JSONSerialization.data(withJSONObject: ["oauthAccount": fields]).write(to: fixture.stateURL)
    let original = fixture.slot.value

    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: fixture.profiles, now: fixture.now) == nil)
    #expect(fixture.slot.value == original)
  }

  @Test(arguments: ["expired", "ambiguous", "weak", "pending"])
  func refusesAnUnusableOrAmbiguousSavedAccount(scenario: String) throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    var saved = fixture.saved
    switch scenario {
    case "expired": saved.payload = try #require(fixture.slot.value)
    case "ambiguous": saved.id = "claude:duplicate"
    case "weak": saved.claudeAccountIdentity?.organizationID = nil
    default: try fixture.registry.savePendingGrant(Data("pending".utf8), id: saved.id)
    }
    try fixture.registry.save(saved)
    let original = fixture.slot.value

    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: fixture.profiles, now: fixture.now) == nil)
    #expect(fixture.slot.value == original)
  }

  @Test func defersUntilClaudeExits() throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    let original = fixture.slot.value
    #expect(throws: AccountSwitchError.self) {
      try fixture.service(active: { _ in ["claude"] }).recoverClaudeCLIIfNeeded(
        profiles: fixture.profiles,
        now: fixture.now
      )
    }
    #expect(fixture.slot.value == original)
    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: fixture.profiles, now: fixture.now) != nil)
  }

  @Test func preservesALoginReplacedAtTheWriteBoundary() throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    let slot = fixture.slot
    let external = Data(#"{"claudeAiOauth":{"accessToken":"external","refreshToken":"external-refresh"}}"#.utf8)
    let interlock = AutomaticRecoveryInterlock {
      slot.value = external
    }

    #expect(throws: AccountSwitchError.self) {
      try fixture.service(active: interlock.inspect).recoverClaudeCLIIfNeeded(
        profiles: fixture.profiles,
        now: fixture.now
      )
    }
    #expect(slot.value == external)
  }

  @Test func rollsBackIfTerminalIdentityChangesDuringInstallation() throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    let original = fixture.slot.value
    let stateURL = fixture.stateURL
    let external = Data(#"{"oauthAccount":{"accountUuid":"external","organizationUuid":"other"}}"#.utf8)
    let interlock = AutomaticRecoveryInterlock {
      try external.write(to: stateURL)
    }

    #expect(throws: AccountSwitchError.self) {
      try fixture.service(active: interlock.inspect).recoverClaudeCLIIfNeeded(
        profiles: fixture.profiles,
        now: fixture.now
      )
    }
    #expect(fixture.slot.value == original)
    #expect(try Data(contentsOf: stateURL) == external)
  }

  @Test func readFailuresNeverAuthorizeAnOverwrite() throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    let original = fixture.slot.value
    let service = fixture.service(read: { _ in throw CocoaError(.fileReadNoPermission) })
    #expect(throws: AccountSwitchError.self) {
      try service.recoverClaudeCLIIfNeeded(profiles: fixture.profiles, now: fixture.now)
    }
    #expect(fixture.slot.value == original)
  }
}

private final class ClaudeAutomaticRecoveryFixture {
  let home: URL
  let registry = makeSwitchRegistry()
  let slot =
    KeychainSlot(
      Data(
        #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":1000},"other":"preserved"}"#
          .utf8
      )
    )
  let now = Date(timeIntervalSince1970: 5000)
  let source = ProviderCredentialSource.claudeKeychain(service: ClaudeCredentialsStore.keychainService)
  let profile = ClaudeProfile(accountID: "account", email: "same@example.com", organizationID: "organization")
  let saved: CapturedAccount

  var stateURL: URL {
    home.appendingPathComponent(".claude.json")
  }

  var fileURL: URL {
    home.appendingPathComponent(".claude/.credentials.json")
  }

  var fileSource: ProviderCredentialSource {
    .claudeCredentialsFile(path: fileURL.path)
  }

  var liveID: String {
    ProviderAccount.id(provider: .claude, source: source)
  }

  var profiles: [String: ClaudeProfile] {
    [liveID: profile.verified(for: ProviderCredentialIdentity.fingerprint(of: "old-access"))]
  }

  init() throws {
    home = try switchTemporaryHome()
    saved = CapturedAccount(
      id: "claude:saved", provider: .claude, displayName: "Saved", detail: nil,
      capturedAt: now, origin: source,
      payload: Data(
        #"{"claudeAiOauth":{"accessToken":"saved-access","refreshToken":"saved-refresh","expiresAt":9999999999999}}"#
          .utf8
      ),
      claudeAccountIdentity: ClaudeAccountIdentity(profile: profile)
    )
    try registry.save(saved)
    try Data(#"{"theme":"dark","oauthAccount":{"accountUuid":"account","organizationUuid":"organization"}}"#.utf8)
      .write(to: stateURL)
  }

  deinit { try? FileManager.default.removeItem(at: home) }

  func service(
    active: @escaping @Sendable (UsageProvider) throws -> [String] = { _ in [] },
    read: (@Sendable (String) throws -> Data?)? = nil
  ) -> AccountSwitchService {
    let slot = slot
    return AccountSwitchService(
      capturedAccounts: registry, environment: [:], home: home,
      keychainRead: read ?? { _ in slot.value },
      keychainWrite: { data, _ in slot.value = data },
      keychainDelete: { _ in slot.value = nil },
      activeCLIProcesses: active
    )
  }
}

private final class AutomaticRecoveryInterlock: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private let action: @Sendable () throws -> Void

  init(action: @escaping @Sendable () throws -> Void) {
    self.action = action
  }

  func inspect(_: UsageProvider) throws -> [String] {
    let shouldRun = lock.withLock { count += 1; return count == 2 }
    if shouldRun {
      try action()
    }
    return []
  }
}
