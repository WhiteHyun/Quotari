import Foundation
@testable import Quotari
@testable import QuotariCore

/// Shared helpers and doubles for the notification-scope test suites.
extension UsageStoreNotificationTests {
  func weeklyFetchResult(accountName: String?) -> ProviderFetchResult {
    ProviderFetchResult(
      usage: weeklyUsage(accountName: accountName),
      sourceLabel: "Live",
      sourceKind: .api
    )
  }

  func weeklyUsage(accountName: String?) -> UsageSnapshot {
    UsageSnapshot(
      provider: .codex,
      account: accountName,
      secondary: RateWindow(
        kind: .weekly,
        usedPercent: 20,
        resetsAt: now.addingTimeInterval(7 * 24 * 3600)
      ),
      updatedAt: now
    )
  }

  func emptyDescriptor(for provider: UsageProvider) -> ProviderDescriptor {
    ProviderDescriptor(
      id: provider,
      metadata: ProviderMetadata(
        displayName: provider.rawValue,
        accent: .init(0, 0, 0),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [] }
    )
  }

  func codexAccount(name: String, identity: String, path: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: name,
      detail: nil,
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: identity
    )
  }

  func claudeAccount(
    name: String = "Claude Code",
    detail: String? = nil,
    identity: String? = nil,
    source: ProviderCredentialSource = .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
  ) -> ProviderAccount {
    ProviderAccount(
      provider: .claude,
      displayName: name,
      detail: detail,
      credentialSource: source,
      credentialIdentity: identity
    )
  }

  func setClaudeProfile(
    _ store: UsageStore,
    for account: ProviderAccount,
    accountID: String,
    token: String
  ) {
    store.claudeProfiles[account.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: token)
    )
  }

  func applyLiveCodexFetch(_ store: UsageStore, scopeID: String) {
    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Live",
        sourceKind: .oauth,
        credentialScopeID: scopeID
      ),
      provider: .codex,
      account: nil
    )
  }

  func applyClaudeFetch(_ store: UsageStore, scopeID: String, account: ProviderAccount?) {
    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: scopeID),
      provider: .claude,
      account: account
    )
  }

  func applyClaudeFetch(
    _ store: UsageStore,
    snapshot: UsageSnapshot,
    scopeID: String,
    account: ProviderAccount?
  ) {
    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: snapshot,
        sourceLabel: "Claude",
        sourceKind: .oauth,
        credentialScopeID: scopeID
      ),
      provider: .claude,
      account: account
    )
  }

  func claudeRotationSnapshot() -> UsageSnapshot {
    UsageSnapshot(
      provider: .claude,
      primary: RateWindow(
        kind: .session,
        usedPercent: 80,
        resetsAt: now.addingTimeInterval(6 * 3600)
      ),
      secondary: RateWindow(
        kind: .weekly,
        usedPercent: 20,
        resetsAt: now.addingTimeInterval(8 * 24 * 3600)
      ),
      updatedAt: now.addingTimeInterval(60)
    )
  }
}

final class NotificationTokenBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String

  init(_ value: String) {
    storage = value
  }

  var value: String {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

actor GatedNotificationAccountDiscovery: ProviderAccountDiscovering {
  private let account: ProviderAccount
  private var requestStarted = false
  private var isReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(account: ProviderAccount) {
    self.account = account
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    requestStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    if !isReleased {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return account.provider == provider ? [account] : []
  }

  func waitUntilRequestStarts() async {
    guard !requestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resume() {
    isReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
