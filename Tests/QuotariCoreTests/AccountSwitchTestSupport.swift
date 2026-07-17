import Foundation
@testable import QuotariCore
import Testing

/// An in-memory Claude-keychain slot the switch can read and write.
final class KeychainSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Data?

  init(_ initial: Data? = nil) {
    storage = initial
  }

  var value: Data? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

func makeSwitchRegistry() -> CapturedAccountStore {
  CapturedAccountStore(keychain: InMemoryKeychain().store, service: "Test-Switch-\(UUID().uuidString)")
}

func savedCodexAccount(registry: CapturedAccountStore) throws -> CapturedAccount {
  let saved = CapturedAccount(
    id: "codex:acct-saved",
    provider: .codex,
    displayName: "Saved Codex",
    detail: "Personal",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .codexAuthFile(path: "/tmp/old.json"),
    payload: Data(#"{"tokens":{"access_token":"saved-tok","account_id":"acct-saved","refresh_token":"saved-ref"}}"#
      .utf8)
  )
  try registry.save(saved)
  return saved
}

func savedClaudeAccount(registry: CapturedAccountStore) throws -> CapturedAccount {
  try savedClaudeAccount(
    registry: registry,
    claudeOAuthAccount: Data(
      #"{"accountUuid":"saved-id","emailAddress":"saved@example.com"}"#.utf8
    )
  )
}

func savedClaudeAccount(
  registry: CapturedAccountStore,
  claudeOAuthAccount: Data?
) throws -> CapturedAccount {
  let saved = CapturedAccount(
    id: "claude:fp-saved",
    provider: .claude,
    displayName: "Saved Claude",
    detail: "Keychain",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: "Claude Code-credentials"),
    payload: Data(#"{"claudeAiOauth":{"accessToken":"saved-tok","refreshToken":"saved-ref","expiresAt":9999999999999}}"#
      .utf8),
    claudeOAuthAccount: claudeOAuthAccount
  )
  try registry.save(saved)
  return saved
}

func switchTemporaryHome() throws -> URL {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("switch-home-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

func verifiedClaudeLiveIdentity(
  source: ProviderCredentialSource,
  accessToken: String,
  accountID: String,
  email: String
) -> VerifiedLiveClaudeIdentity {
  let fingerprint = ProviderCredentialIdentity.fingerprint(of: accessToken)
  return VerifiedLiveClaudeIdentity(
    source: source,
    accessTokenFingerprint: fingerprint,
    profile: ClaudeProfile(
      accountID: accountID,
      email: email,
      fingerprint: fingerprint
    )
  )
}

func switchClaudeWithVerifiedLiveIdentity(
  _ service: AccountSwitchService,
  to id: String,
  source: ProviderCredentialSource,
  accessToken: String,
  profile: ClaudeProfile
) throws {
  let fingerprint = ProviderCredentialIdentity.fingerprint(of: accessToken)
  try service.switchCLI(
    toRegistryAccount: id,
    now: Date(timeIntervalSince1970: 5000),
    verifiedLiveClaudeIdentity: VerifiedLiveClaudeIdentity(
      source: source,
      accessTokenFingerprint: fingerprint,
      profile: ClaudeProfile(
        accountID: profile.accountID,
        email: profile.email,
        fingerprint: fingerprint
      )
    )
  )
}

func claudeSwitchPayload(accessToken: String, refreshToken: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
  )
}

func claudeSwitchRegistryID(accessToken: String, refreshToken: String) -> String {
  let fingerprint = ProviderCredentialIdentity.claudeIdentity(
    refreshToken: refreshToken,
    accessToken: accessToken
  )
  return "claude:\(fingerprint ?? "")"
}

func expectClaudeIdentity(
  _ identity: Data?,
  accountID: String,
  email: String
) throws {
  #expect(try ClaudeCodeAccountState.matches(
    #require(identity),
    profile: ClaudeProfile(accountID: accountID, email: email)
  ))
}

func makeClaudeBackupSwitchService(
  registry: CapturedAccountStore,
  home: URL,
  keychain: KeychainSlot
) -> AccountSwitchService {
  AccountSwitchService(
    capturedAccounts: registry,
    capture: AccountCaptureService(capturedAccounts: registry, claudeKeychainRead: { _ in keychain.value }),
    environment: [:],
    home: home,
    keychainRead: { _ in keychain.value },
    keychainWrite: { data, _ in keychain.value = data }
  )
}
