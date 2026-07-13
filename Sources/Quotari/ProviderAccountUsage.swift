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
  let task: Task<Void, Never>
  let force: Bool
}

/// A selection change decided during account rediscovery: the account to
/// select now, and — when it is a live stand-in for a hidden saved copy —
/// the saved account the selection logically remains on.
struct SelectionUpdate {
  var account: ProviderAccount
  var origin: ProviderAccount?
}
