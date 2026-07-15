import Foundation
import QuotariCore

struct DeferredClaudeQuotaNotification {
  var snapshot: UsageSnapshot
  var account: ProviderAccount?
  var sourceKind: ProviderFetchKind?
  var credentialScopeID: String?
  var revision: UInt
  var updatesNotificationScope: Bool

  var storageKey: String {
    account?.id ?? credentialScopeID.map { "scope:\($0)" } ?? "automatic"
  }
}

enum QuotaNotificationAccountResolution {
  case resolved(String)
  case deferredClaudeIdentity
  case staleCredential
  case unattributed

  var logicalAccountID: String? {
    guard case let .resolved(id) = self else { return nil }
    return id
  }
}

private struct QuotaNotificationDispatch {
  var snapshot: UsageSnapshot
  var provider: UsageProvider
  var account: ProviderAccount?
  var sourceKind: ProviderFetchKind?
  var credentialScopeID: String?
  var revision: UInt
  var updatesNotificationScope: Bool
}

extension UsageStore {
  func enqueueQuotaNotification(
    snapshot: UsageSnapshot,
    provider: UsageProvider,
    account: ProviderAccount?,
    sourceKind: ProviderFetchKind?,
    credentialScopeID: String?
  ) {
    guard isProviderEnabled(provider) else { return }
    // Automatic mode has no selected account to establish scope. Its real
    // results update scope inside the serial notification tail below: this
    // keeps a reactivation's nil-scope drain ahead of the fresh identity and
    // prevents a pre-disable snapshot from being revived. A transient mock
    // fallback preserves the last real scope and cannot notify.
    let updatesNotificationScope = account == nil && sourceKind != .mock
    let revision = accountRevisions[provider] ?? 0
    let previous = quotaNotificationTask
    quotaNotificationTask = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      await processQuotaNotification(
        QuotaNotificationDispatch(
          snapshot: snapshot,
          provider: provider,
          account: account,
          sourceKind: sourceKind,
          credentialScopeID: credentialScopeID,
          revision: revision,
          updatesNotificationScope: updatesNotificationScope
        )
      )
    }
  }

  private func processQuotaNotification(_ request: QuotaNotificationDispatch) async {
    let provider = request.provider
    let revision = request.revision
    guard isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == revision
    else { return }
    let resolution = await quotaNotificationAccountResolution(
      snapshot: request.snapshot,
      provider: provider,
      account: request.account,
      sourceKind: request.sourceKind,
      credentialScopeID: request.credentialScopeID
    )
    guard isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == revision
    else { return }
    guard applyQuotaNotificationResolution(resolution, request: request) else { return }

    let logicalAccountID = resolution.logicalAccountID
    if let account = request.account, let logicalAccountID {
      notificationScopeIDsByAccountID[account.id] = logicalAccountID
    }
    let controller = quotaNotifications
    if request.updatesNotificationScope {
      if let logicalAccountID {
        synchronizeQuotaNotificationScope(
          logicalAccountID: logicalAccountID,
          provider: provider
        )
      } else {
        synchronizeQuotaNotificationScope(
          account: selectedAccounts[provider],
          origin: reconciledSelectionOrigins[provider],
          provider: provider
        )
      }
    } else if let account = request.account,
              scopedNotificationAccountIDs[provider]?.contains(account.id) == true,
              let logicalAccountID {
      // An unattributed automatic fetch clears stale scope first. Restore each
      // explicit account only after its credential fetch succeeds.
      controller.addActiveLogicalAccountID(logicalAccountID, for: provider)
    }
    _ = await controller.process(
      snapshot: request.snapshot,
      logicalAccountID: logicalAccountID,
      sourceKind: request.sourceKind,
      now: request.snapshot.updatedAt,
      isCurrent: { [weak self] in
        guard let self else { return false }
        return isProviderEnabled(provider)
          && (accountRevisions[provider] ?? 0) == revision
      }
    )
  }

  /// Applies the side effects of a resolution and reports whether processing
  /// should continue to the notification controller. `false` means the request
  /// was deferred or dropped and the caller must return early.
  private func applyQuotaNotificationResolution(
    _ resolution: QuotaNotificationAccountResolution,
    request: QuotaNotificationDispatch
  ) -> Bool {
    let provider = request.provider
    switch resolution {
    case .deferredClaudeIdentity:
      let deferred = DeferredClaudeQuotaNotification(
        snapshot: request.snapshot,
        account: request.account,
        sourceKind: request.sourceKind,
        credentialScopeID: request.credentialScopeID,
        revision: request.revision,
        updatesNotificationScope: request.updatesNotificationScope
      )
      deferredClaudeQuotaNotifications[deferred.storageKey] = deferred
      return false
    case .staleCredential:
      if provider == .claude {
        removeDeferredClaudeQuotaNotification(for: request)
      }
      removeStaleQuotaNotificationScope(for: request)
      return false
    case .resolved:
      if provider == .claude {
        removeDeferredClaudeQuotaNotification(for: request)
      }
      return true
    case .unattributed:
      if provider == .claude, request.sourceKind != .mock {
        removeDeferredClaudeQuotaNotification(for: request)
      }
      return true
    }
  }

  func enqueueClaudeQuotaNotificationScopeRestore() {
    let provider = UsageProvider.claude
    let revision = accountRevisions[provider] ?? 0
    let previous = quotaNotificationTask
    quotaNotificationTask = Task { [weak self] in
      await previous?.value
      guard let self,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == revision
      else { return }
      let deferredNotifications = deferredClaudeQuotaNotifications.values
        .sorted { $0.storageKey < $1.storageKey }
      var replayedCurrentRevision = false
      for deferred in deferredNotifications {
        guard deferred.revision == revision else {
          deferredClaudeQuotaNotifications[deferred.storageKey] = nil
          continue
        }
        replayedCurrentRevision = true
        await processQuotaNotification(
          QuotaNotificationDispatch(
            snapshot: deferred.snapshot,
            provider: provider,
            account: deferred.account,
            sourceKind: deferred.sourceKind,
            credentialScopeID: deferred.credentialScopeID,
            revision: deferred.revision,
            updatesNotificationScope: deferred.updatesNotificationScope
          )
        )
      }
      if !replayedCurrentRevision, deferredClaudeQuotaNotifications.isEmpty {
        synchronizeQuotaNotificationScope(
          account: selectedAccounts[provider],
          origin: reconciledSelectionOrigins[provider],
          provider: provider
        )
      }
    }
  }

  private func removeDeferredClaudeQuotaNotification(
    for request: QuotaNotificationDispatch
  ) {
    let key = request.account?.id
      ?? request.credentialScopeID.map { "scope:\($0)" }
      ?? "automatic"
    deferredClaudeQuotaNotifications[key] = nil
  }

  private func removeStaleQuotaNotificationScope(
    for request: QuotaNotificationDispatch
  ) {
    guard let account = request.account else {
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[request.provider],
        origin: reconciledSelectionOrigins[request.provider],
        provider: request.provider
      )
      return
    }
    if let logicalAccountID = lastKnownNotificationScopeID(for: account) {
      let keepsSharedScope = scopedNotificationAccountIDs[request.provider]?.contains { accountID in
        accountID != account.id
          && notificationScopeIDsByAccountID[accountID] == logicalAccountID
      } == true
      if !keepsSharedScope {
        quotaNotifications.removeActiveLogicalAccountID(logicalAccountID, for: request.provider)
      }
      notificationScopeIDsByAccountID[account.id] = nil
    } else {
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[request.provider],
        origin: reconciledSelectionOrigins[request.provider],
        provider: request.provider
      )
    }
  }

  func enqueueQuotaNotificationScopeRestore(for provider: UsageProvider) {
    let revision = accountRevisions[provider] ?? 0
    let previous = quotaNotificationTask
    quotaNotificationTask = Task { [weak self] in
      await previous?.value
      guard let self,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == revision
      else { return }
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[provider],
        origin: reconciledSelectionOrigins[provider],
        provider: provider
      )
    }
  }

  func waitForPendingQuotaNotifications() async {
    await quotaNotificationTask?.value
  }

  func synchronizeQuotaNotificationScope(
    account: ProviderAccount?,
    origin: ProviderAccount?,
    provider: UsageProvider
  ) {
    let logicalAccount = provider == .claude ? account : (origin ?? account)
    var scopedAccountIDs = Set((monitoredAccounts[provider] ?? []).flatMap {
      notificationBookkeepingAccountIDs(for: $0)
    })
    if let account {
      scopedAccountIDs.formUnion(notificationBookkeepingAccountIDs(for: account))
    }
    if let origin {
      scopedAccountIDs.formUnion(notificationBookkeepingAccountIDs(for: origin))
    }
    scopedNotificationAccountIDs[provider] = scopedAccountIDs
    let scopeID = logicalAccount.flatMap { notificationScopeID(for: $0) }
    if let logicalAccount, let scopeID {
      recordNotificationScopeID(scopeID, for: logicalAccount)
    }
    synchronizeQuotaNotificationScope(logicalAccountID: scopeID, provider: provider)
  }

  func synchronizeQuotaNotificationScope(
    logicalAccountID: String?,
    provider: UsageProvider
  ) {
    guard isProviderEnabled(provider) else {
      quotaNotifications.setActiveLogicalAccountIDs([], for: provider)
      return
    }
    var logicalAccountIDs = Set<String>((monitoredAccounts[provider] ?? []).compactMap { account in
      guard let scopeID = notificationScopeID(for: account) else { return nil }
      recordNotificationScopeID(scopeID, for: account)
      return scopeID
    })
    if let logicalAccountID {
      logicalAccountIDs.insert(logicalAccountID)
    }
    quotaNotifications.setActiveLogicalAccountIDs(logicalAccountIDs, for: provider)
  }

  private func notificationBookkeepingAccountIDs(for account: ProviderAccount) -> Set<String> {
    Set([account.id, capturedEquivalents[account.id]?.id].compactMap(\.self))
  }

  private func recordNotificationScopeID(_ scopeID: String, for account: ProviderAccount) {
    for accountID in notificationBookkeepingAccountIDs(for: account) {
      notificationScopeIDsByAccountID[accountID] = scopeID
    }
  }
}
