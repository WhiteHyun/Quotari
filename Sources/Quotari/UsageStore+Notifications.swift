import Foundation
import QuotariCore

struct DeferredClaudeQuotaNotification {
  var snapshot: UsageSnapshot
  var account: ProviderAccount?
  var sourceKind: ProviderFetchKind?
  var credentialScopeID: String?
  var revision: UInt
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
    let controller = quotaNotifications
    if request.updatesNotificationScope {
      controller.setActiveLogicalAccountID(logicalAccountID, for: provider)
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
      deferredClaudeQuotaNotification = DeferredClaudeQuotaNotification(
        snapshot: request.snapshot,
        account: request.account,
        sourceKind: request.sourceKind,
        credentialScopeID: request.credentialScopeID,
        revision: request.revision
      )
      return false
    case .staleCredential:
      if provider == .claude {
        deferredClaudeQuotaNotification = nil
      }
      quotaNotifications.setActiveLogicalAccountID(nil, for: provider)
      return false
    case .resolved:
      if provider == .claude {
        deferredClaudeQuotaNotification = nil
      }
      return true
    case .unattributed:
      if provider == .claude, request.sourceKind != .mock {
        deferredClaudeQuotaNotification = nil
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
      if let deferred = deferredClaudeQuotaNotification {
        guard deferred.revision == revision else {
          deferredClaudeQuotaNotification = nil
          synchronizeQuotaNotificationScope(
            account: selectedAccounts[provider],
            origin: reconciledSelectionOrigins[provider],
            provider: provider
          )
          return
        }
        await processQuotaNotification(
          QuotaNotificationDispatch(
            snapshot: deferred.snapshot,
            provider: provider,
            account: deferred.account,
            sourceKind: deferred.sourceKind,
            credentialScopeID: deferred.credentialScopeID,
            revision: deferred.revision,
            updatesNotificationScope: deferred.sourceKind != .mock
          )
        )
        return
      }
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[provider],
        origin: reconciledSelectionOrigins[provider],
        provider: provider
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
    let scopeID = logicalAccount.flatMap { notificationScopeID(for: $0) }
    quotaNotifications.setActiveLogicalAccountID(
      isProviderEnabled(provider) ? scopeID : nil,
      for: provider
    )
  }
}
