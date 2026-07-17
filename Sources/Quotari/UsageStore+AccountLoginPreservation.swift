import Foundation
import QuotariCore

extension UsageStore {
  func combinedLoginError(_ loginError: String, restorationError: String?) -> String {
    guard let restorationError else { return loginError }
    return "\(loginError) Quotari also encountered a recovery error: \(restorationError)"
  }

  func accountRegistryBaseline(for provider: UsageProvider) async throws -> AccountLoginRegistryBaseline? {
    guard provider == .claude else { return nil }
    let capture = accountCapture
    let accounts = try await Task.detached {
      try capture.registeredAccounts(for: provider)
    }.value
    return AccountLoginRegistryBaseline(accounts)
  }

  func preserveCredentialImmediatelyBeforeLogin(
    provider: UsageProvider,
    source: ProviderCredentialSource,
    payload: Data?,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline?
  ) async throws {
    guard provider == .claude, let registryBaseline else { return }
    let accountState = try await currentClaudeAccountState()
    if let payload {
      try await preserveClaudeCredentialAtLoginBoundary(
        payload,
        source: source,
        previousClaudeLogin: previousClaudeLogin,
        registryBaseline: registryBaseline,
        accountState: accountState
      )
    }
    guard try await currentClaudeAccountState() == accountState else {
      throw AccountLoginError.credentialChangedDuringPreparation(.claude)
    }
    registryBaseline.recordClaudeLogin(keychainPayload: payload, accountState: accountState)
  }

  private func preserveClaudeCredentialAtLoginBoundary(
    _ payload: Data,
    source: ProviderCredentialSource,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline,
    accountState: Data?
  ) async throws {
    guard let minimized = ProviderCredentialMinimizer.minimize(provider: .claude, payload: payload) else {
      if ProviderCredentialMinimizer.hasAccessToken(provider: .claude, payload: payload) {
        throw AddedAccountImportError.preservationFailed
      }
      return
    }
    guard let credentials = try? ClaudeCredentialsStore.parse(payload) else {
      throw AddedAccountImportError.preservationFailed
    }
    let profile = try await profileFetcher.fetchProfile(accessToken: credentials.accessToken)
    guard profile.hasStableAccountIdentity else {
      throw AddedAccountImportError.savedIdentityUnverified
    }
    let verifiedProfile = profile.verified(
      for: ProviderCredentialIdentity.fingerprint(of: credentials.accessToken)
    )
    let oauthAccount = currentClaudeOAuthAccount(for: profile, accountState: accountState)
    if let saved = try await uniquelyMatchingSavedClaudeAccount(
      for: profile,
      previousClaudeLogin: previousClaudeLogin,
      registryBaseline: registryBaseline
    ) {
      let refreshed = try await refreshReauthenticatedClaudeAccount(
        saved,
        payload: payload,
        profile: verifiedProfile,
        claudeOAuthAccount: oauthAccount,
        requiresNewerGenerationEvidence: true
      )
      guard refreshed.payload == minimized else {
        throw AddedAccountImportError.preservationFailed
      }
      registryBaseline.recordClaudeBoundaryAccount(refreshed)
      return
    }
    let capture = accountCapture
    let captured = try await Task.detached {
      try capture.captureRawPayload(
        provider: .claude,
        origin: source,
        payload: payload,
        now: Date(),
        claudeOAuthAccount: oauthAccount
      )
    }.value
    guard let captured else { throw AddedAccountImportError.preservationFailed }
    registryBaseline.recordClaudeBoundaryAccount(captured)
  }

  private func currentClaudeAccountState() async throws -> Data? {
    let switcher = accountSwitch
    return try await Task.detached {
      try switcher.claudeAccountStateSnapshot()
    }.value
  }

  private func currentClaudeOAuthAccount(
    for profile: ClaudeProfile,
    accountState: Data?
  ) -> Data? {
    let candidate = accountState.flatMap { try? ClaudeCodeAccountState.oauthAccount(from: $0) } ?? nil
    return resolvedClaudeOAuthAccount(candidate: candidate, profile: profile)
  }
}

final class AccountLoginRegistryBaseline: @unchecked Sendable {
  private let lock = NSLock()
  private var registeredAccounts: [String: ProviderAccount]
  private var claudeKeychainSnapshotStorage: ClaudeKeychainLoginSnapshot?
  private var claudePostLoginSnapshotStorage: ClaudeKeychainLoginSnapshot?
  private var mutationPossible = false

  init(_ accounts: [CapturedAccount]) {
    registeredAccounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.providerAccount) })
  }

  var registeredProviderAccounts: [ProviderAccount] {
    lock.withLock { Array(registeredAccounts.values) }
  }

  func recordClaudeLogin(keychainPayload: Data?, accountState: Data?) {
    lock.withLock {
      claudeKeychainSnapshotStorage = ClaudeKeychainLoginSnapshot(
        payload: keychainPayload,
        accountState: accountState
      )
    }
  }

  var claudeKeychainSnapshot: ClaudeKeychainLoginSnapshot? {
    lock.withLock { claudeKeychainSnapshotStorage }
  }

  func recordClaudePostLogin(keychainPayload: Data?, accountState: Data?) {
    lock.withLock {
      claudePostLoginSnapshotStorage = ClaudeKeychainLoginSnapshot(
        payload: keychainPayload,
        accountState: accountState
      )
    }
  }

  var claudePostLoginSnapshot: ClaudeKeychainLoginSnapshot? {
    lock.withLock { claudePostLoginSnapshotStorage }
  }

  func recordClaudeBoundaryAccount(_ account: CapturedAccount) {
    lock.withLock {
      let providerAccount = account.providerAccount
      registeredAccounts[account.id] = providerAccount
    }
  }

  func markCredentialMutationPossible() {
    lock.withLock { mutationPossible = true }
  }

  var isCredentialMutationPossible: Bool {
    lock.withLock { mutationPossible }
  }
}

struct ClaudeKeychainLoginSnapshot: Sendable {
  let payload: Data?
  let accountState: Data?
}
