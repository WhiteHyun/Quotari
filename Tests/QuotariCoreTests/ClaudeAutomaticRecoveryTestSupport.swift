import Foundation
@testable import QuotariCore

final class ClaudeAutomaticRecoveryFixture {
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

final class AutomaticRecoveryInterlock: @unchecked Sendable {
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
