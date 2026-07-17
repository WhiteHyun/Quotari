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
    registryBaseline.recordClaudeKeychain(payload)
    guard let payload else { return }
    guard ProviderCredentialMinimizer.minimize(provider: provider, payload: payload) != nil else {
      if ProviderCredentialMinimizer.hasAccessToken(provider: provider, payload: payload) {
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
    if let saved = try await uniquelyMatchingSavedClaudeAccount(
      for: profile,
      previousClaudeLogin: previousClaudeLogin,
      registryBaseline: registryBaseline
    ) {
      let refreshed = try await refreshReauthenticatedClaudeAccount(
        saved,
        payload: payload,
        profile: verifiedProfile,
        requiresNewerGenerationEvidence: true
      )
      registryBaseline.recordClaudeBoundaryAccount(refreshed)
      return
    }
    let capture = accountCapture
    let captured = try await Task.detached {
      try capture.captureRawPayload(
        provider: provider,
        origin: source,
        payload: payload,
        now: Date()
      )
    }.value
    guard let captured else { throw AddedAccountImportError.preservationFailed }
    registryBaseline.recordClaudeBoundaryAccount(captured)
  }
}

final class AccountLoginRegistryBaseline: @unchecked Sendable {
  private let lock = NSLock()
  private var registeredAccounts: [String: ProviderAccount]
  private var claudeKeychainSnapshotStorage: ClaudeKeychainLoginSnapshot?
  private var claudePostLoginKeychainSnapshotStorage: ClaudeKeychainLoginSnapshot?
  private var mutationPossible = false

  init(_ accounts: [CapturedAccount]) {
    registeredAccounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.providerAccount) })
  }

  var registeredProviderAccounts: [ProviderAccount] {
    lock.withLock { Array(registeredAccounts.values) }
  }

  func recordClaudeKeychain(_ payload: Data?) {
    lock.withLock {
      claudeKeychainSnapshotStorage = ClaudeKeychainLoginSnapshot(payload: payload)
    }
  }

  var claudeKeychainSnapshot: ClaudeKeychainLoginSnapshot? {
    lock.withLock { claudeKeychainSnapshotStorage }
  }

  func recordClaudePostLoginKeychain(_ payload: Data?) {
    lock.withLock {
      claudePostLoginKeychainSnapshotStorage = ClaudeKeychainLoginSnapshot(payload: payload)
    }
  }

  var claudePostLoginKeychainSnapshot: ClaudeKeychainLoginSnapshot? {
    lock.withLock { claudePostLoginKeychainSnapshotStorage }
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
}
