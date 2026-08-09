import Foundation
import QuotariCore

extension UsageStore {
  func combinedLoginError(_ loginError: String, restorationError: String?) -> String {
    guard let restorationError else { return loginError }
    return L10n.string("\(loginError) Quotari also encountered a recovery error: \(restorationError)")
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
    let boundaryAccount: CapturedAccount? = if let payload {
      try await preserveClaudeCredentialAtLoginBoundary(
        payload,
        source: source,
        previousClaudeLogin: previousClaudeLogin,
        registryBaseline: registryBaseline,
        evidence: ClaudeLoginCredentialEvidence(
          accountState: accountState,
          requiresNewerGenerationEvidence: true
        )
      )
    } else {
      nil
    }
    guard try await currentClaudeAccountState() == accountState else {
      throw AccountLoginError.credentialChangedDuringPreparation(.claude)
    }
    registryBaseline.recordClaudeLogin(
      keychainPayload: payload,
      accountState: accountState,
      accountID: boundaryAccount?.id
    )
  }

  func preserveCredentialDuringLogin(
    provider: UsageProvider,
    source: ProviderCredentialSource,
    payload: Data?,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline?
  ) async throws {
    guard provider == .claude, let registryBaseline else { return }
    let accountState = try await currentClaudeAccountState()
    let boundaryAccount: CapturedAccount? = if let payload {
      try await preserveClaudeCredentialAtLoginBoundary(
        payload,
        source: source,
        previousClaudeLogin: previousClaudeLogin,
        registryBaseline: registryBaseline,
        evidence: ClaudeLoginCredentialEvidence(
          accountState: accountState,
          // Sampling after the pre-login boundary directly establishes ordering,
          // even when Claude omits expiry dates while rotating its refresh token.
          requiresNewerGenerationEvidence: false
        )
      )
    } else {
      nil
    }
    guard try await currentClaudeAccountState() == accountState else {
      throw AccountLoginError.credentialChangedDuringPreparation(.claude)
    }
    registryBaseline.recordClaudeRotation(
      keychainPayload: payload,
      accountID: boundaryAccount?.id
    )
  }

  private func preserveClaudeCredentialAtLoginBoundary(
    _ payload: Data,
    source: ProviderCredentialSource,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline,
    evidence: ClaudeLoginCredentialEvidence
  ) async throws -> CapturedAccount? {
    guard let minimized = ProviderCredentialMinimizer.minimize(provider: .claude, payload: payload) else {
      if ProviderCredentialMinimizer.hasAccessToken(provider: .claude, payload: payload) {
        throw AddedAccountImportError.preservationFailed
      }
      return nil
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
    let oauthAccount = currentClaudeOAuthAccount(for: profile, accountState: evidence.accountState)
    if let saved = try await matchingSavedClaudeAccount(
      for: profile,
      previousClaudeLogin: previousClaudeLogin,
      registryBaseline: registryBaseline
    ) {
      let refreshed = try await refreshReauthenticatedClaudeAccount(
        saved,
        payload: payload,
        profile: verifiedProfile,
        claudeOAuthAccount: oauthAccount,
        requiresNewerGenerationEvidence: evidence.requiresNewerGenerationEvidence
      )
      guard refreshed.payload == minimized else {
        throw AddedAccountImportError.preservationFailed
      }
      registryBaseline.recordClaudeBoundaryAccount(refreshed)
      return refreshed
    }
    let capture = accountCapture
    let captured = try await Task.detached {
      try capture.captureRawPayload(
        provider: .claude,
        origin: source,
        payload: payload,
        now: Date(),
        claudeOAuthAccount: oauthAccount,
        claudeAccountIdentity: verifiedProfile.accountIdentity
      )
    }.value
    guard let captured else { throw AddedAccountImportError.preservationFailed }
    registryBaseline.recordClaudeBoundaryAccount(captured)
    return captured
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

private struct ClaudeLoginCredentialEvidence {
  let accountState: Data?
  let requiresNewerGenerationEvidence: Bool
}

final class AccountLoginRegistryBaseline: @unchecked Sendable {
  private let lock = NSLock()
  private var registeredAccounts: [String: ProviderAccount]
  private var claudeKeychainSnapshotStorage: ClaudeKeychainLoginSnapshot?
  private var claudeRestoreAccountID: String?
  private var hasClaudeKeychainSnapshot = false
  private var claudePostLoginSnapshotStorage: ClaudeKeychainLoginSnapshot?
  private var mutationPossible = false

  init(_ accounts: [CapturedAccount]) {
    registeredAccounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.providerAccount) })
  }

  var registeredProviderAccounts: [ProviderAccount] {
    lock.withLock { Array(registeredAccounts.values) }
  }

  func recordClaudeLogin(keychainPayload: Data?, accountState: Data?, accountID: String?) {
    lock.withLock {
      hasClaudeKeychainSnapshot = true
      claudeRestoreAccountID = accountID
      claudeKeychainSnapshotStorage = ClaudeKeychainLoginSnapshot(
        payload: keychainPayload,
        accountState: accountState
      )
    }
  }

  func recordClaudeRotation(keychainPayload: Data?, accountID: String?) {
    lock.withLock {
      guard hasClaudeKeychainSnapshot,
            let claudeRestoreAccountID,
            accountID == claudeRestoreAccountID,
            let snapshot = claudeKeychainSnapshotStorage
      else { return }
      claudeKeychainSnapshotStorage = ClaudeKeychainLoginSnapshot(
        payload: keychainPayload,
        accountState: snapshot.accountState
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
