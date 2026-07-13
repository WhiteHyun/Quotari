import Foundation
@testable import Quotari
import Testing

extension QuotaNotificationPolicyTests {
  @Test func accountScopeClearsOnlyOtherResetsAndRetainsThresholdHistory() throws {
    var policy = QuotaNotificationPolicy()
    let resetAt = now.addingTimeInterval(3600)
    let accountAEvaluation = evaluate(
      .init(
        weeklyUsed: 80,
        weeklyResetAt: resetAt,
        logicalAccountID: "account-a"
      ),
      using: &policy
    )
    let accountAWarning = try #require(
      accountAEvaluation.requests.first(where: { $0.kind == .warning })
    )
    let accountAReset = try #require(
      accountAEvaluation.requests.first(where: { $0.kind == .weeklyReset })
    )
    accountAEvaluation.requests.forEach { policy.recordSuccess(for: $0) }

    let accountBEvaluation = evaluate(
      .init(
        weeklyUsed: 20,
        weeklyResetAt: resetAt,
        logicalAccountID: "account-b"
      ),
      using: &policy
    )
    let accountBReset = try #require(accountBEvaluation.requests.first)
    policy.recordSuccess(for: accountBReset)

    let cleared = policy.clearScheduledResets(
      for: .codex,
      keeping: "account-b"
    )

    #expect(cleared == [accountAReset.requestID])
    #expect(policy.ledger.windows[accountAReset.key]?.scheduledReset == nil)
    #expect(policy.ledger.windows[accountAWarning.key]?.deliveredThresholds == [.warning])
    #expect(
      policy.ledger.windows[accountBReset.key]?.scheduledReset?.requestID
        == accountBReset.requestID
    )
  }
}
