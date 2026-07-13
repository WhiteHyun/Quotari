import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension UsageStoreNotificationTests {
  @Test func selectedCodexLiveResultRejectsAReplacedCredential() async throws {
    let path = "/tmp/selected-codex-replaced-auth.json"
    let selected = ProviderAccount(
      provider: .codex,
      displayName: "Selected Codex login",
      detail: nil,
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: "acct-selected"
    )
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Replacement Codex login",
      detail: nil,
      credentialSource: selected.credentialSource,
      credentialIdentity: "acct-replacement"
    )
    let harness = try await makeStore(
      "selected-codex-replaced-credential",
      codexCredentialLoader: { _ in
        CodexCredentials(accessToken: "replacement-token", accountID: "acct-replacement")
      }
    )
    let store = harness.store
    let center = harness.center
    store.synchronizeQuotaNotificationScope(
      account: selected,
      origin: nil,
      provider: .codex
    )

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Codex",
        sourceKind: .oauth,
        credentialScopeID: replacement.credentialScopeID
      ),
      provider: .codex,
      account: selected
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
  }

  @Test func selectedClaudeDeferredSnapshotRestoresScopeAfterProfileFetch() async throws {
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let selected = ProviderAccount(
      provider: .claude,
      displayName: "Selected Claude login",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "selected-claude-token"
    )
    let harness = try await makeStore(
      "selected-claude-deferred-scope",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "selected-claude-token") }
    )
    let store = harness.store
    let center = harness.center
    store.synchronizeQuotaNotificationScope(
      account: selected,
      origin: nil,
      provider: .claude
    )

    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: selected.credentialScopeID),
      provider: .claude,
      account: selected
    )
    await store.waitForPendingQuotaNotifications()
    #expect(center.attemptedRequests.isEmpty)

    let accountID = "selected-claude-account"
    store.claudeProfiles[selected.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "selected-claude-token")
    )
    store.enqueueClaudeQuotaNotificationScopeRestore()
    await store.waitForPendingQuotaNotifications()

    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(center.attemptedRequests.map(\.key.logicalAccountID) == [logicalAccountID, logicalAccountID])
  }
}
