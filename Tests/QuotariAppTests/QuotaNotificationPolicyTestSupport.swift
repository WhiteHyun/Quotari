import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

struct QuotaNotificationEvaluationInput {
  var sessionUsed: Double?
  var sessionResetAt: Date?
  var weeklyUsed: Double?
  var weeklyResetAt: Date?
  var provider: UsageProvider = .codex
  var logicalAccountID = "account-a"
  var sourceKind: ProviderFetchKind? = .api
  var preferences = QuotaNotificationPreferences(isEnabled: true)
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

struct ScheduledResetFixture {
  var codexWarning: QuotaNotificationRequest
  var codexReset: QuotaNotificationRequest
  var claudeReset: QuotaNotificationRequest
}

extension QuotaNotificationPolicyTests {
  func input(
    for window: QuotaNotificationWindow,
    usedPercent: Double,
    resetAt: Date?,
    now: Date? = nil
  ) -> QuotaNotificationEvaluationInput {
    switch window {
    case .session:
      QuotaNotificationEvaluationInput(
        sessionUsed: usedPercent,
        sessionResetAt: resetAt,
        now: now ?? self.now
      )
    case .weekly:
      QuotaNotificationEvaluationInput(
        weeklyUsed: usedPercent,
        weeklyResetAt: resetAt,
        now: now ?? self.now
      )
    }
  }

  func scheduledWeeklyReset(
    in policy: inout QuotaNotificationPolicy
  ) throws -> QuotaNotificationRequest {
    let evaluation = evaluate(
      .init(weeklyUsed: 20, weeklyResetAt: now.addingTimeInterval(3600)),
      using: &policy
    )
    let request = try #require(evaluation.requests.first)
    policy.recordSuccess(for: request)
    return request
  }

  func recordScheduledResets(
    in policy: inout QuotaNotificationPolicy,
    resetAt: Date
  ) throws -> ScheduledResetFixture {
    let codexEvaluation = evaluate(
      .init(
        sessionUsed: 80,
        sessionResetAt: resetAt,
        weeklyUsed: 20,
        weeklyResetAt: resetAt,
        logicalAccountID: "codex-account"
      ),
      using: &policy
    )
    let codexWarning = try #require(codexEvaluation.requests.first(where: { $0.kind == .warning }))
    let codexReset = try #require(codexEvaluation.requests.first(where: { $0.kind == .weeklyReset }))
    policy.recordSuccess(for: codexWarning)
    policy.recordSuccess(for: codexReset)

    let claudeEvaluation = evaluate(
      .init(
        weeklyUsed: 20,
        weeklyResetAt: resetAt,
        provider: .claude,
        logicalAccountID: "claude-account"
      ),
      using: &policy
    )
    let claudeReset = try #require(claudeEvaluation.requests.first)
    policy.recordSuccess(for: claudeReset)
    return ScheduledResetFixture(
      codexWarning: codexWarning,
      codexReset: codexReset,
      claudeReset: claudeReset
    )
  }

  func evaluate(
    _ input: QuotaNotificationEvaluationInput,
    using policy: inout QuotaNotificationPolicy
  ) -> QuotaNotificationEvaluation {
    policy.evaluate(
      snapshot: UsageSnapshot(
        provider: input.provider,
        primary: input.sessionUsed.map {
          RateWindow(kind: .session, usedPercent: $0, resetsAt: input.sessionResetAt)
        },
        secondary: input.weeklyUsed.map {
          RateWindow(kind: .weekly, usedPercent: $0, resetsAt: input.weeklyResetAt)
        },
        updatedAt: input.now
      ),
      logicalAccountID: input.logicalAccountID,
      sourceKind: input.sourceKind,
      preferences: input.preferences,
      now: input.now
    )
  }
}
