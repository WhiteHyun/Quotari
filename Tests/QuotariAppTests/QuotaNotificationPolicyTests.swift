import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

struct QuotaNotificationPolicyTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func thresholdsRetryUntilSuccessAndOnlyDeliverOncePerCycle() throws {
    var policy = QuotaNotificationPolicy()
    let resetAt = now.addingTimeInterval(3600)

    let belowWarning = evaluate(
      .init(sessionUsed: 79, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    )
    #expect(belowWarning.requests.isEmpty)

    let warning = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.first)
    #expect(warning.kind == .warning)
    #expect(warning.threshold == 80)

    let failedDeliveryRetry = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.first)
    #expect(failedDeliveryRetry == warning)

    policy.recordSuccess(for: warning)
    #expect(evaluate(
      .init(sessionUsed: 80, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.isEmpty)

    let critical = try #require(evaluate(
      .init(sessionUsed: 95, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.first)
    #expect(critical.kind == .critical)
    #expect(critical.threshold == 95)
    policy.recordSuccess(for: critical)

    #expect(evaluate(
      .init(sessionUsed: 100, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.isEmpty)
  }

  @Test func firstCriticalObservationEmitsOnlyCriticalAndMarksBothThresholdsOnSuccess() throws {
    var policy = QuotaNotificationPolicy()
    let resetAt = now.addingTimeInterval(3600)

    let evaluation = evaluate(.init(sessionUsed: 96, sessionResetAt: resetAt), using: &policy)
    let request = try #require(evaluation.requests.first)
    #expect(evaluation.requests.count == 1)
    #expect(request.kind == .critical)

    let key = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: "account-a",
      window: .session
    )
    #expect(policy.ledger.windows[key]?.deliveredThresholds == [])

    policy.recordSuccess(for: request)
    #expect(policy.ledger.windows[key]?.deliveredThresholds == [.warning, .critical])
  }

  @Test func deliveryHistoryIsIndependentByAccountProviderAndWindow() throws {
    var policy = QuotaNotificationPolicy()
    let resetAt = now.addingTimeInterval(3600)

    let first = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.first)
    policy.recordSuccess(for: first)

    #expect(evaluate(
      .init(sessionUsed: 80, sessionResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.isEmpty)

    let otherAccount = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: resetAt, logicalAccountID: "account-b", sourceKind: .oauth),
      using: &policy
    ).requests.first(where: { $0.kind == .warning }))
    let otherProvider = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: resetAt, provider: .claude, sourceKind: .oauth),
      using: &policy
    ).requests.first(where: { $0.kind == .warning }))
    let otherWindow = try #require(evaluate(
      .init(weeklyUsed: 80, weeklyResetAt: resetAt, sourceKind: .oauth),
      using: &policy
    ).requests.first(where: { $0.kind == .warning }))

    #expect(Set([first.key, otherAccount.key, otherProvider.key, otherWindow.key]).count == 4)
    #expect(Set([first.requestID, otherAccount.requestID, otherProvider.requestID, otherWindow.requestID]).count == 4)
  }
}

extension QuotaNotificationPolicyTests {
  @Test func resetDateDriftWithinToleranceKeepsThresholdHistoryAndReplacesTheSchedule() throws {
    var policy = QuotaNotificationPolicy()
    let resetAt = now.addingTimeInterval(3600)
    let initial = evaluate(.init(weeklyUsed: 80, weeklyResetAt: resetAt), using: &policy)
    let warning = try #require(initial.requests.first(where: { $0.kind == .warning }))
    let scheduledReset = try #require(initial.requests.first(where: { $0.kind == .weeklyReset }))
    policy.recordSuccess(for: warning)
    policy.recordSuccess(for: scheduledReset)

    let drifted = evaluate(
      .init(
        weeklyUsed: 80,
        weeklyResetAt: resetAt.addingTimeInterval(QuotaNotificationPolicy.resetDateTolerance - 1),
        now: now.addingTimeInterval(60)
      ),
      using: &policy
    )

    let replacement = try #require(drifted.requests.first)
    #expect(drifted.requests.count == 1)
    #expect(replacement.kind == .weeklyReset)
    #expect(replacement.requestID == scheduledReset.requestID)
    #expect(replacement.deliverAt == resetAt.addingTimeInterval(QuotaNotificationPolicy.resetDateTolerance - 1))
    #expect(drifted.cancellationRequestIDs.isEmpty)
    #expect(
      policy.ledger.windows[warning.key]?.cycleResetAt
        == resetAt.addingTimeInterval(QuotaNotificationPolicy.resetDateTolerance - 1)
    )
    #expect(policy.ledger.windows[warning.key]?.deliveredThresholds == [.warning])
    #expect(policy.ledger.windows[warning.key]?.scheduledReset?.requestID == scheduledReset.requestID)
  }

  @Test func resetDateCorrectionBeforeTheBoundaryDoesNotRearmThresholds() throws {
    var policy = QuotaNotificationPolicy()
    let firstReset = now.addingTimeInterval(3600)
    let warning = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: firstReset),
      using: &policy
    ).requests.first)
    policy.recordSuccess(for: warning)

    let correctedReset = firstReset.addingTimeInterval(QuotaNotificationPolicy.resetDateTolerance + 1)
    let correction = evaluate(.init(sessionUsed: 80, sessionResetAt: correctedReset), using: &policy)

    #expect(correction.requests.isEmpty)
    #expect(policy.ledger.windows[warning.key]?.cycleResetAt == correctedReset)
    #expect(policy.ledger.windows[warning.key]?.cycleSequence == warning.cycleSequence)
    #expect(policy.ledger.windows[warning.key]?.deliveredThresholds == [.warning])
  }

  @Test func aDifferentFutureResetDateWithALargeUsageDropStartsANewCycle() throws {
    var policy = QuotaNotificationPolicy()
    let firstReset = now.addingTimeInterval(3600)
    let critical = try #require(evaluate(
      .init(sessionUsed: 96, sessionResetAt: firstReset), using: &policy
    ).requests.first)
    policy.recordSuccess(for: critical)

    let nextReset = now.addingTimeInterval(7200)
    _ = evaluate(.init(
      sessionUsed: 40, sessionResetAt: nextReset, now: now.addingTimeInterval(60)
    ), using: &policy)
    let state = try #require(policy.ledger.windows[critical.key])
    #expect(state.cycleSequence == critical.cycleSequence + 1)
    #expect(state.deliveredThresholds.isEmpty)
    let warning = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: nextReset, now: now.addingTimeInterval(120)), using: &policy
    ).requests.first(where: { $0.kind == .warning }))
    #expect(warning.requestID != critical.requestID)
  }

  @Test func aPassedBoundaryRearmsThresholdsWithoutPreemptivelyMarkingTheRetry() throws {
    var policy = QuotaNotificationPolicy()
    let firstReset = now.addingTimeInterval(60)
    let warning = try #require(evaluate(
      .init(sessionUsed: 80, sessionResetAt: firstReset),
      using: &policy
    ).requests.first)
    policy.recordSuccess(for: warning)

    let nextReset = now.addingTimeInterval(7200)
    let nextCycle = evaluate(
      .init(sessionUsed: 80, sessionResetAt: nextReset, now: firstReset.addingTimeInterval(1)),
      using: &policy
    )
    let nextWarning = try #require(nextCycle.requests.first)

    #expect(nextWarning.kind == .warning)
    #expect(nextWarning.requestID != warning.requestID)
    #expect(policy.ledger.windows[warning.key]?.cycleResetAt == nextReset)
    #expect(policy.ledger.windows[warning.key]?.deliveredThresholds == [])
  }

  @Test func anUndatedFiftyPointDropBelowWarningRearmsThresholds() throws {
    var policy = QuotaNotificationPolicy()
    let critical = try #require(evaluate(
      .init(sessionUsed: 96),
      using: &policy
    ).requests.first)
    policy.recordSuccess(for: critical)

    let resetObservation = evaluate(
      .init(sessionUsed: 40, now: now.addingTimeInterval(60)),
      using: &policy
    )
    #expect(resetObservation.requests.isEmpty)
    #expect(policy.ledger.windows[critical.key]?.deliveredThresholds == [])

    let warning = try #require(evaluate(
      .init(sessionUsed: 80, now: now.addingTimeInterval(120)),
      using: &policy
    ).requests.first)
    #expect(warning.kind == .warning)
    #expect(warning.requestID != critical.requestID)
  }

  @Test(arguments: [QuotaNotificationWindow.session, .weekly])
  func aReturnedResetDateWithALargeUsageDropRearmsThresholds(
    window: QuotaNotificationWindow
  ) throws {
    var policy = QuotaNotificationPolicy()
    let firstReset = now.addingTimeInterval(3600)
    let initial = evaluate(
      input(for: window, usedPercent: 96, resetAt: firstReset),
      using: &policy
    )
    let critical = try #require(initial.requests.first(where: { $0.kind == .critical }))
    let scheduledReset = initial.requests.first(where: { $0.kind == .weeklyReset })
    initial.requests.forEach { policy.recordSuccess(for: $0) }

    let missingDate = evaluate(
      input(for: window, usedPercent: 96, resetAt: nil, now: now.addingTimeInterval(60)),
      using: &policy
    )
    #expect(missingDate.requests.isEmpty)
    #expect(missingDate.cancellationRequestIDs == scheduledReset.map { [$0.requestID] } ?? [])
    for cancellationRequestID in missingDate.cancellationRequestIDs {
      policy.recordCancellationSuccess(requestID: cancellationRequestID)
    }

    let nextReset = now.addingTimeInterval(7200)
    _ = evaluate(
      input(for: window, usedPercent: 40, resetAt: nextReset, now: now.addingTimeInterval(120)),
      using: &policy
    )
    let state = try #require(policy.ledger.windows[critical.key])
    #expect(state.cycleResetAt == nextReset)
    #expect(state.cycleSequence == critical.cycleSequence + 1)
    #expect(state.deliveredThresholds.isEmpty)

    let warning = try #require(evaluate(
      input(for: window, usedPercent: 80, resetAt: nextReset, now: now.addingTimeInterval(180)),
      using: &policy
    ).requests.first(where: { $0.kind == .warning }))
    #expect(warning.requestID != critical.requestID)
  }
}

extension QuotaNotificationPolicyTests {
  @Test func expiredWindowsDoNotMutateTheLedgerOrProduceRequests() {
    var policy = QuotaNotificationPolicy()
    let expired = evaluate(.init(sessionUsed: 96, sessionResetAt: now), using: &policy)
    #expect(expired == QuotaNotificationEvaluation())
    #expect(policy.ledger.windows.isEmpty)
  }

  @Test func weeklyResetSchedulingRetriesThenReplacesAChangedResetDate() throws {
    var policy = QuotaNotificationPolicy()
    let firstReset = now.addingTimeInterval(3600)
    let initial = evaluate(.init(weeklyUsed: 20, weeklyResetAt: firstReset), using: &policy)
    let firstRequest = try #require(initial.requests.first)
    #expect(initial.requests.count == 1)
    #expect(firstRequest.kind == .weeklyReset)
    #expect(firstRequest.deliverAt == firstReset)

    let schedulingRetry = try #require(evaluate(
      .init(weeklyUsed: 20, weeklyResetAt: firstReset),
      using: &policy
    ).requests.first)
    #expect(schedulingRetry == firstRequest)

    policy.recordSuccess(for: firstRequest)
    #expect(evaluate(
      .init(weeklyUsed: 20, weeklyResetAt: firstReset),
      using: &policy
    ) == QuotaNotificationEvaluation())

    let secondReset = firstReset.addingTimeInterval(QuotaNotificationPolicy.resetDateTolerance + 60)
    let changed = evaluate(.init(weeklyUsed: 20, weeklyResetAt: secondReset), using: &policy)
    let replacement = try #require(changed.requests.first)

    #expect(changed.cancellationRequestIDs.isEmpty)
    #expect(replacement.kind == .weeklyReset)
    #expect(replacement.requestID == firstRequest.requestID)
    #expect(replacement.deliverAt == secondReset)

    policy.recordSuccess(for: replacement)
    #expect(policy.ledger.windows[replacement.key]?.scheduledReset?.requestID == replacement.requestID)
  }

  @Test func aMissingWeeklyWindowCancelsItsPreviouslyScheduledReset() throws {
    var policy = QuotaNotificationPolicy()
    let scheduled = try scheduledWeeklyReset(in: &policy)

    let missing = evaluate(.init(), using: &policy)

    #expect(missing.requests.isEmpty)
    #expect(missing.cancellationRequestIDs == [scheduled.requestID])
  }

  @Test func anExpiredOrUndatedWeeklyWindowCancelsItsStaleSchedule() throws {
    var expiredPolicy = QuotaNotificationPolicy()
    let expiredSchedule = try scheduledWeeklyReset(in: &expiredPolicy)
    let expired = evaluate(
      .init(weeklyUsed: 20, weeklyResetAt: now, now: now),
      using: &expiredPolicy
    )
    #expect(expired.cancellationRequestIDs == [expiredSchedule.requestID])

    var undatedPolicy = QuotaNotificationPolicy()
    let undatedSchedule = try scheduledWeeklyReset(in: &undatedPolicy)
    let undated = evaluate(.init(weeklyUsed: 20), using: &undatedPolicy)
    #expect(undated.cancellationRequestIDs == [undatedSchedule.requestID])
    #expect(undatedPolicy.ledger.windows[undatedSchedule.key]?.cycleResetAt == nil)
  }
}

extension QuotaNotificationPolicyTests {
  @Test func disablingGloballyOrPerProviderCancelsResetsButRetainsThresholdHistory() throws {
    var policy = QuotaNotificationPolicy()
    let resetAt = now.addingTimeInterval(3600)
    let fixture = try recordScheduledResets(
      in: &policy,
      resetAt: resetAt
    )

    let providerDisabled = evaluate(
      .init(
        weeklyUsed: 20,
        weeklyResetAt: resetAt,
        logicalAccountID: "codex-account",
        preferences: QuotaNotificationPreferences(isEnabled: true, enabledProviders: [.claude])
      ),
      using: &policy
    )
    #expect(providerDisabled.requests.isEmpty)
    #expect(providerDisabled.cancellationRequestIDs == [fixture.codexReset.requestID])
    policy.recordCancellationSuccess(requestID: fixture.codexReset.requestID)

    let globallyDisabled = evaluate(
      .init(
        weeklyUsed: 20,
        weeklyResetAt: resetAt,
        provider: .claude,
        logicalAccountID: "claude-account",
        preferences: QuotaNotificationPreferences()
      ),
      using: &policy
    )
    #expect(globallyDisabled.requests.isEmpty)
    #expect(globallyDisabled.cancellationRequestIDs == [fixture.claudeReset.requestID])
    policy.recordCancellationSuccess(requestID: fixture.claudeReset.requestID)

    #expect(policy.ledger.windows[fixture.codexWarning.key]?.deliveredThresholds == [.warning])
    #expect(policy.ledger.windows[fixture.codexReset.key]?.scheduledReset == nil)
    #expect(policy.ledger.windows[fixture.claudeReset.key]?.scheduledReset == nil)
  }

  @Test func ledgerRoundTripsThroughCodable() throws {
    var policy = QuotaNotificationPolicy()
    let resetAt = now.addingTimeInterval(3600)
    let evaluation = evaluate(.init(weeklyUsed: 96, weeklyResetAt: resetAt), using: &policy)
    for request in evaluation.requests {
      policy.recordSuccess(for: request)
    }

    let encoded = try JSONEncoder().encode(policy.ledger)
    let decoded = try JSONDecoder().decode(QuotaNotificationLedger.self, from: encoded)

    #expect(decoded == policy.ledger)
  }
}
