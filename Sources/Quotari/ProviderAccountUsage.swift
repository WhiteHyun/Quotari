import Foundation
import QuotariCore

struct ProviderAccountUsage: Sendable {
  var snapshot: UsageSnapshot?
  var sourceLabel: String?
  var sourceKind: ProviderFetchKind?
  var error: String?

  init(
    snapshot: UsageSnapshot? = nil,
    sourceLabel: String? = nil,
    sourceKind: ProviderFetchKind? = nil,
    error: String? = nil
  ) {
    self.snapshot = snapshot
    self.sourceLabel = sourceLabel
    self.sourceKind = sourceKind
    self.error = error
  }
}

struct AccountUsageRefreshTask {
  let task: Task<[String: Set<String>], Never>
  let force: Bool
  let credentialScopeIDs: Set<String>

  init(
    task: Task<[String: Set<String>], Never>,
    force: Bool,
    credentialScopeIDs: Set<String> = []
  ) {
    self.task = task
    self.force = force
    self.credentialScopeIDs = credentialScopeIDs
  }

  init(
    task: Task<Void, Never>,
    force: Bool,
    credentialScopeIDs: Set<String> = []
  ) {
    self.task = Task {
      await task.value
      return [:]
    }
    self.force = force
    self.credentialScopeIDs = credentialScopeIDs
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
