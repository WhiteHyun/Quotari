import Foundation
import QuotariCore

struct ProviderAccountUsage: Sendable {
  var snapshot: UsageSnapshot?
  var sourceLabel: String?
  var sourceKind: ProviderFetchKind?
  /// Credential generation that produced `snapshot`. Cached OAuth replay must
  /// validate this value rather than the account row discovered before a token
  /// rotation completed.
  var credentialScopeID: String?
  var error: String?

  init(
    snapshot: UsageSnapshot? = nil,
    sourceLabel: String? = nil,
    sourceKind: ProviderFetchKind? = nil,
    credentialScopeID: String? = nil,
    error: String? = nil
  ) {
    self.snapshot = snapshot
    self.sourceLabel = sourceLabel
    self.sourceKind = sourceKind
    self.credentialScopeID = credentialScopeID
    self.error = error
  }
}

struct AccountUsageNotificationCandidate: Sendable {
  let account: ProviderAccount
  let result: ProviderFetchResult
}

struct AccountUsageRefreshOutcome: Sendable {
  var credentialTransitions: [String: Set<String>] = [:]
  var notificationCandidates: [AccountUsageNotificationCandidate] = []
}

struct AccountUsageRefreshRequest {
  let force: Bool
  let notifiesQuota: Bool
  let includingLogicalAccountIDs: Set<String>?
  let excludingCredentialScopeIDs: Set<String>
  let interaction: ProviderFetchInteraction
  let bypassesDelayedCredentialRefresh: Bool

  init(
    force: Bool,
    notifiesQuota: Bool,
    includingLogicalAccountIDs: Set<String>?,
    excludingCredentialScopeIDs: Set<String>,
    interaction: ProviderFetchInteraction = .background,
    bypassesDelayedCredentialRefresh: Bool = false
  ) {
    self.force = force
    self.notifiesQuota = notifiesQuota
    self.includingLogicalAccountIDs = includingLogicalAccountIDs
    self.excludingCredentialScopeIDs = excludingCredentialScopeIDs
    self.interaction = interaction
    self.bypassesDelayedCredentialRefresh = bypassesDelayedCredentialRefresh
  }
}

struct AccountUsageRefreshExecution {
  let descriptor: ProviderDescriptor
  let accounts: [ProviderAccount]
  let now: Date
  let revision: UInt
  let notifiesQuota: Bool
  let interaction: ProviderFetchInteraction
}

struct AccountUsageRefreshTask {
  let task: Task<AccountUsageRefreshOutcome, Never>
  let force: Bool
  let notifiesQuota: Bool
  let revision: UInt?
  let credentialScopeIDs: Set<String>
  let interaction: ProviderFetchInteraction

  init(
    task: Task<AccountUsageRefreshOutcome, Never>,
    force: Bool,
    notifiesQuota: Bool,
    revision: UInt,
    credentialScopeIDs: Set<String> = [],
    interaction: ProviderFetchInteraction = .background
  ) {
    self.task = task
    self.force = force
    self.notifiesQuota = notifiesQuota
    self.revision = revision
    self.credentialScopeIDs = credentialScopeIDs
    self.interaction = interaction
  }

  init(
    task: Task<Void, Never>,
    force: Bool,
    notifiesQuota: Bool = false,
    revision: UInt? = nil,
    credentialScopeIDs: Set<String> = [],
    interaction: ProviderFetchInteraction = .background
  ) {
    self.task = Task {
      await task.value
      return AccountUsageRefreshOutcome()
    }
    self.force = force
    self.notifiesQuota = notifiesQuota
    self.revision = revision
    self.credentialScopeIDs = credentialScopeIDs
    self.interaction = interaction
  }
}

/// A selection change decided during account rediscovery: the account to
/// select now, and — when it is a live stand-in for a hidden saved copy —
/// the saved account the selection logically remains on.
struct SelectionUpdate {
  /// `nil` explicitly clears a selection whose source-stable row was reused
  /// by another credential before Quotari could preserve the chosen identity.
  var account: ProviderAccount?
  var origin: ProviderAccount?
}
