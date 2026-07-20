import Foundation
import QuotariCore

enum QuotaNotificationWindow: String, Codable, Equatable, Hashable, Sendable {
  case session
  case weekly
}

struct QuotaNotificationWindowKey: Codable, Equatable, Hashable, Sendable {
  var provider: UsageProvider
  var logicalAccountID: String
  var window: QuotaNotificationWindow
}

enum QuotaNotificationKind: String, Codable, Equatable, Hashable, Sendable {
  case warning
  case critical
  case weeklyReset
}

enum QuotaNotificationThreshold: String, Codable, Equatable, Hashable, Sendable {
  case warning
  case critical
}

struct QuotaNotificationRequest: Equatable, Sendable {
  var requestID: String
  var key: QuotaNotificationWindowKey
  var kind: QuotaNotificationKind
  var threshold: Int?
  var observedUsedPercent: Double?
  /// Nil for an immediate threshold notification; non-nil for a scheduled reset.
  var deliverAt: Date?
  /// The canonical reset date identifying the cycle this request belongs to.
  var cycleResetAt: Date?
  var cycleSequence: UInt64
}

struct QuotaNotificationEvaluation: Equatable, Sendable {
  var requests: [QuotaNotificationRequest] = []
  var cancellationRequestIDs: [String] = []
}

struct QuotaNotificationScheduledReset: Codable, Equatable, Sendable {
  var requestID: String
  var deliverAt: Date
}

struct QuotaNotificationWindowState: Codable, Equatable, Sendable {
  var cycleResetAt: Date?
  var cycleSequence: UInt64 = 0
  var lastObservedUsedPercent: Double?
  var deliveredThresholds: Set<QuotaNotificationThreshold> = []
  var scheduledReset: QuotaNotificationScheduledReset?
}

struct QuotaNotificationLedger: Codable, Equatable, Sendable {
  var windows: [QuotaNotificationWindowKey: QuotaNotificationWindowState] = [:]
}

private struct QuotaNotificationRequestDetails {
  var kind: QuotaNotificationKind
  var threshold: Int?
  var usedPercent: Double?
  var deliverAt: Date?
}

/// Pure notification policy. Call `evaluate` serially for fresh provider snapshots,
/// persist `ledger`, and report notification-center success through `recordSuccess`.
struct QuotaNotificationPolicy: Equatable, Sendable {
  static let resetDateTolerance: TimeInterval = 5 * 60

  var ledger: QuotaNotificationLedger

  init(ledger: QuotaNotificationLedger = QuotaNotificationLedger()) {
    self.ledger = ledger
  }

  mutating func evaluate(
    snapshot: UsageSnapshot,
    logicalAccountID: String,
    sourceKind: ProviderFetchKind?,
    preferences: QuotaNotificationPreferences,
    now: Date
  ) -> QuotaNotificationEvaluation {
    if !preferences.isEnabled {
      return QuotaNotificationEvaluation(
        cancellationRequestIDs: pendingResetRequestIDs { _ in true }
      )
    }
    guard preferences.enabledProviders.contains(snapshot.provider) else {
      return QuotaNotificationEvaluation(
        cancellationRequestIDs: pendingResetRequestIDs { $0.provider == snapshot.provider }
      )
    }
    var evaluation = QuotaNotificationEvaluation()
    evaluate(
      window: snapshot.primary,
      key: QuotaNotificationWindowKey(
        provider: snapshot.provider,
        logicalAccountID: logicalAccountID,
        window: .session
      ),
      preferences: preferences,
      now: now,
      evaluation: &evaluation
    )
    evaluate(
      window: snapshot.secondary,
      key: QuotaNotificationWindowKey(
        provider: snapshot.provider,
        logicalAccountID: logicalAccountID,
        window: .weekly
      ),
      preferences: preferences,
      now: now,
      evaluation: &evaluation
    )
    evaluation.cancellationRequestIDs = Array(Set(evaluation.cancellationRequestIDs)).sorted()
    return evaluation
  }

  /// Call only after the notification center accepts an immediate or scheduled request.
  /// Evaluation itself never marks threshold delivery, so failed requests remain eligible.
  mutating func recordSuccess(for request: QuotaNotificationRequest) {
    guard var state = ledger.windows[request.key],
          state.cycleSequence == request.cycleSequence
    else { return }

    switch request.kind {
    case .warning:
      state.deliveredThresholds.insert(.warning)
    case .critical:
      state.deliveredThresholds.formUnion([.warning, .critical])
    case .weeklyReset:
      guard request.key.window == .weekly, let deliverAt = request.deliverAt else { return }
      state.scheduledReset = QuotaNotificationScheduledReset(
        requestID: request.requestID,
        deliverAt: deliverAt
      )
    }
    ledger.windows[request.key] = state
  }

  /// Call after removing a pending request. Threshold delivery history is intentionally retained.
  mutating func recordCancellationSuccess(requestID: String) {
    for key in Array(ledger.windows.keys) {
      guard var state = ledger.windows[key], state.scheduledReset?.requestID == requestID else { continue }
      state.scheduledReset = nil
      ledger.windows[key] = state
    }
  }
}

private extension QuotaNotificationPolicy {
  private mutating func evaluate(
    window: RateWindow?,
    key: QuotaNotificationWindowKey,
    preferences: QuotaNotificationPreferences,
    now: Date,
    evaluation: inout QuotaNotificationEvaluation
  ) {
    guard let window, window.kind == key.window.usageWindowKind else {
      appendScheduledResetCancellation(for: key, evaluation: &evaluation)
      return
    }
    if let resetsAt = window.resetsAt, resetsAt <= now {
      appendScheduledResetCancellation(for: key, evaluation: &evaluation)
      return
    }

    let state = updatedState(
      for: window,
      key: key,
      preferences: preferences,
      now: now
    )
    ledger.windows[key] = state

    if let request = thresholdRequest(
      key: key,
      state: state,
      usedPercent: window.usedPercent,
      preferences: preferences
    ) {
      evaluation.requests.append(request)
    }
    appendWeeklyResetEvaluation(
      key: key,
      state: state,
      now: now,
      evaluation: &evaluation
    )
  }

  private func updatedState(
    for window: RateWindow,
    key: QuotaNotificationWindowKey,
    preferences: QuotaNotificationPreferences,
    now: Date
  ) -> QuotaNotificationWindowState {
    var state = ledger.windows[key] ?? QuotaNotificationWindowState()
    let previousResetAt = state.cycleResetAt
    let previousUsedPercent = state.lastObservedUsedPercent
    let usageReset = Self.isLargeUsageDrop(
      previousUsedPercent: previousUsedPercent,
      currentUsedPercent: window.usedPercent,
      warningThreshold: preferences.warningThreshold
    )
    if previousUsedPercent == nil {
      state.cycleResetAt = window.resetsAt
    } else if window.resetsAt == nil, usageReset {
      state.cycleResetAt = nil
      state.cycleSequence &+= 1
      state.deliveredThresholds.removeAll()
    } else if let resetAt = window.resetsAt {
      let isCorrection = !(previousResetAt == nil && usageReset)
        && (previousResetAt == nil
          || Self.isSameCycle(previousResetAt, resetAt)
          || (!usageReset && previousResetAt.map { $0 > now } == true))
      state.cycleResetAt = resetAt
      if !isCorrection {
        state.cycleSequence &+= 1
        state.deliveredThresholds.removeAll()
      }
    } else {
      // A provider can temporarily stop reporting a reset date while the
      // usage window remains available. Do not leave the old OS request
      // scheduled for a time the latest provider response no longer claims.
      state.cycleResetAt = nil
    }
    state.lastObservedUsedPercent = window.usedPercent
    return state
  }

  private func appendWeeklyResetEvaluation(
    key: QuotaNotificationWindowKey,
    state: QuotaNotificationWindowState,
    now: Date,
    evaluation: inout QuotaNotificationEvaluation
  ) {
    guard key.window == .weekly else { return }
    guard let resetAt = state.cycleResetAt, resetAt > now else {
      if let scheduledReset = state.scheduledReset {
        evaluation.cancellationRequestIDs.append(scheduledReset.requestID)
      }
      return
    }

    let resetRequest = makeRequest(
      key: key,
      state: state,
      details: QuotaNotificationRequestDetails(
        kind: .weeklyReset,
        threshold: nil,
        usedPercent: nil,
        deliverAt: resetAt
      )
    )
    guard state.scheduledReset?.deliverAt != resetRequest.deliverAt else { return }
    evaluation.requests.append(resetRequest)
  }

  private func appendScheduledResetCancellation(
    for key: QuotaNotificationWindowKey,
    evaluation: inout QuotaNotificationEvaluation
  ) {
    guard key.window == .weekly,
          let requestID = ledger.windows[key]?.scheduledReset?.requestID
    else { return }
    evaluation.cancellationRequestIDs.append(requestID)
  }

  private func thresholdRequest(
    key: QuotaNotificationWindowKey,
    state: QuotaNotificationWindowState,
    usedPercent: Double,
    preferences: QuotaNotificationPreferences
  ) -> QuotaNotificationRequest? {
    if usedPercent >= Double(preferences.criticalThreshold),
       !state.deliveredThresholds.contains(.critical) {
      return makeRequest(
        key: key,
        state: state,
        details: QuotaNotificationRequestDetails(
          kind: .critical,
          threshold: preferences.criticalThreshold,
          usedPercent: usedPercent,
          deliverAt: nil
        )
      )
    }
    if usedPercent >= Double(preferences.warningThreshold),
       !state.deliveredThresholds.contains(.warning),
       !state.deliveredThresholds.contains(.critical) {
      return makeRequest(
        key: key,
        state: state,
        details: QuotaNotificationRequestDetails(
          kind: .warning,
          threshold: preferences.warningThreshold,
          usedPercent: usedPercent,
          deliverAt: nil
        )
      )
    }
    return nil
  }

  private func makeRequest(
    key: QuotaNotificationWindowKey,
    state: QuotaNotificationWindowState,
    details: QuotaNotificationRequestDetails
  ) -> QuotaNotificationRequest {
    var identityParts = [
      key.provider.rawValue,
      key.logicalAccountID,
      key.window.rawValue,
      details.kind.rawValue,
    ]
    if details.kind != .weeklyReset {
      identityParts.append(String(state.cycleSequence))
      identityParts.append(details.threshold.map(String.init) ?? "none")
    }
    let identity = identityParts.joined(separator: "|")
    return QuotaNotificationRequest(
      requestID: "quotari.quota.\(Self.fnv1a(identity))",
      key: key,
      kind: details.kind,
      threshold: details.threshold,
      observedUsedPercent: details.usedPercent,
      deliverAt: details.deliverAt,
      cycleResetAt: state.cycleResetAt,
      cycleSequence: state.cycleSequence
    )
  }

  private func pendingResetRequestIDs(
    where shouldInclude: (QuotaNotificationWindowKey) -> Bool
  ) -> [String] {
    ledger.windows
      .filter { shouldInclude($0.key) }
      .compactMap(\.value.scheduledReset?.requestID)
      .sorted()
  }

  private static func isSameCycle(_ lhs: Date?, _ rhs: Date?) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
      abs(lhs.timeIntervalSince(rhs)) <= resetDateTolerance
    case (nil, nil):
      true
    case (.some, nil), (nil, .some):
      false
    }
  }

  private static func isLargeUsageDrop(
    previousUsedPercent: Double?,
    currentUsedPercent: Double,
    warningThreshold: Int
  ) -> Bool {
    guard let previousUsedPercent else { return false }
    return previousUsedPercent - currentUsedPercent >= 50
      && currentUsedPercent < Double(warningThreshold)
  }

  private static func fnv1a(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}

private extension QuotaNotificationWindow {
  var usageWindowKind: UsageWindowKind {
    switch self {
    case .session:
      .session
    case .weekly:
      .weekly
    }
  }
}
