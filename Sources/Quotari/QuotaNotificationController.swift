import Foundation
import Observation
import QuotariCore

struct QuotaNotificationProcessingResult: Equatable, Sendable {
  var acceptedRequestIDs: [String] = []
  var failedRequestIDs: [String] = []
  var cancelledRequestIDs: [String] = []
}

@MainActor
@Observable
final class QuotaNotificationController {
  static let shared = QuotaNotificationController()

  private(set) var preferences: QuotaNotificationPreferences
  private(set) var authorizationStatus: QuotaNotificationAuthorizationStatus = .notDetermined
  private(set) var lastError: String?

  @ObservationIgnored private let center: any QuotaNotificationCenterTransport
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var policy: QuotaNotificationPolicy
  @ObservationIgnored private var processingTail: Task<QuotaNotificationProcessingResult, Never>?
  @ObservationIgnored private var inFlightRequestIDs = Set<String>()
  @ObservationIgnored private var scheduledRequestRevision: UInt = 0
  @ObservationIgnored private var scopedProviders = Set<UsageProvider>()
  @ObservationIgnored private var activeLogicalAccountIDs: [UsageProvider: String] = [:]

  var ledger: QuotaNotificationLedger {
    policy.ledger
  }

  var authorizationMessage: String? {
    authorizationStatus == .denied
      ? "Allow notifications for Quotari in System Settings to enable quota alerts."
      : nil
  }

  init(
    center: any QuotaNotificationCenterTransport = SystemQuotaNotificationCenter(),
    defaults: UserDefaults = .standard
  ) {
    self.center = center
    self.defaults = defaults
    let loadedPreferences = Self.load(
      QuotaNotificationPreferences.self,
      key: PersistenceKey.preferences,
      defaults: defaults
    ) ?? QuotaNotificationPreferences()
    preferences = Self.normalized(loadedPreferences)
    let ledger = Self.load(
      QuotaNotificationLedger.self,
      key: PersistenceKey.ledger,
      defaults: defaults
    ) ?? QuotaNotificationLedger()
    policy = QuotaNotificationPolicy(ledger: ledger)
    if preferences != loadedPreferences {
      Self.save(preferences, key: PersistenceKey.preferences, defaults: defaults)
    }
    center.configureForegroundPresentation()
  }

  @discardableResult
  func refreshAuthorizationStatus() async -> QuotaNotificationAuthorizationStatus {
    let status = await center.authorizationStatus()
    authorizationStatus = status
    if !preferences.isEnabled {
      cancelScheduled(where: { _ in true })
    } else if status.allowsDelivery {
      await reconcilePendingRequests()
    } else {
      preferences.isEnabled = false
      persistPreferences()
      cancelScheduled(where: { _ in true })
    }
    return status
  }

  /// Call from the user-initiated Settings toggle. Permission is requested only
  /// here, never while processing a background usage refresh.
  @discardableResult
  func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
    guard enabled else {
      preferences.isEnabled = false
      persistPreferences()
      cancelScheduled(where: { _ in true })
      lastError = nil
      return true
    }

    var status = await center.authorizationStatus()
    authorizationStatus = status
    if status == .notDetermined {
      do {
        _ = try await center.requestAuthorization()
        status = await center.authorizationStatus()
        authorizationStatus = status
      } catch {
        preferences.isEnabled = false
        persistPreferences()
        lastError = error.localizedDescription
        return false
      }
    }

    guard status.allowsDelivery else {
      preferences.isEnabled = false
      persistPreferences()
      cancelScheduled(where: { _ in true })
      return false
    }
    preferences.isEnabled = true
    persistPreferences()
    await reconcilePendingRequests()
    lastError = nil
    return true
  }

  func setProvider(_ provider: UsageProvider, enabled: Bool) {
    if enabled {
      preferences.enabledProviders.insert(provider)
    } else {
      preferences.enabledProviders.remove(provider)
      cancelScheduled(where: { $0.provider == provider })
    }
    persistPreferences()
  }

  /// Updates the account whose reset schedule is currently relevant for a
  /// provider. Passing nil represents Automatic mode before a fresh result can
  /// be confidently attributed, and therefore clears every prior account's
  /// scheduled reset for that provider.
  @discardableResult
  func setActiveLogicalAccountID(
    _ logicalAccountID: String?,
    for provider: UsageProvider
  ) -> [String] {
    let logicalAccountID = logicalAccountID.flatMap { $0.isEmpty ? nil : $0 }
    scopedProviders.insert(provider)
    activeLogicalAccountIDs[provider] = logicalAccountID

    let identifiers = policy.clearScheduledResets(
      for: provider,
      keeping: logicalAccountID
    )
    guard !identifiers.isEmpty else { return [] }
    center.removePendingRequests(withIdentifiers: identifiers)
    persistLedger()
    return identifiers
  }

  @discardableResult
  func updateThresholds(warning: Int, critical: Int) -> Bool {
    guard (1 ... 99).contains(warning),
          ((warning + 1) ... 100).contains(critical)
    else { return false }
    preferences.warningThreshold = warning
    preferences.criticalThreshold = critical
    persistPreferences()
    return true
  }

  /// Feed each accepted provider result through this method on the main actor.
  /// A center failure is reported in the result and remains eligible next time.
  func process(
    snapshot: UsageSnapshot,
    logicalAccountID: String?,
    sourceKind: ProviderFetchKind?,
    now: Date,
    isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
  ) async -> QuotaNotificationProcessingResult {
    let previous = processingTail
    let task = Task { @MainActor [weak self] in
      _ = await previous?.value
      guard let self else { return QuotaNotificationProcessingResult() }
      return await performProcess(
        snapshot: snapshot,
        logicalAccountID: logicalAccountID,
        sourceKind: sourceKind,
        now: now,
        isCurrent: isCurrent
      )
    }
    processingTail = task
    return await task.value
  }

  private func performProcess(
    snapshot: UsageSnapshot,
    logicalAccountID: String?,
    sourceKind: ProviderFetchKind?,
    now: Date,
    isCurrent: @MainActor @Sendable () -> Bool
  ) async -> QuotaNotificationProcessingResult {
    guard isCurrent(),
          preferences.isEnabled,
          let logicalAccountID,
          !logicalAccountID.isEmpty,
          scopeAllows(provider: snapshot.provider, logicalAccountID: logicalAccountID)
    else { return QuotaNotificationProcessingResult() }

    let status = await center.authorizationStatus()
    authorizationStatus = status
    guard isCurrent(),
          preferences.isEnabled,
          scopeAllows(provider: snapshot.provider, logicalAccountID: logicalAccountID)
    else { return QuotaNotificationProcessingResult() }
    guard status.allowsDelivery else {
      preferences.isEnabled = false
      persistPreferences()
      let cancelled = cancelScheduled(where: { _ in true })
      return QuotaNotificationProcessingResult(cancelledRequestIDs: cancelled)
    }
    await reconcilePendingRequests()
    guard isCurrent(),
          preferences.isEnabled,
          scopeAllows(provider: snapshot.provider, logicalAccountID: logicalAccountID)
    else { return QuotaNotificationProcessingResult() }

    let evaluation = policy.evaluate(
      snapshot: snapshot,
      logicalAccountID: logicalAccountID,
      sourceKind: sourceKind,
      preferences: preferences,
      now: now
    )
    return await deliver(evaluation, isCurrent: isCurrent)
  }
}

private extension QuotaNotificationController {
  func deliver(
    _ evaluation: QuotaNotificationEvaluation,
    isCurrent: @MainActor @Sendable () -> Bool
  ) async -> QuotaNotificationProcessingResult {
    persistLedger()
    var result = QuotaNotificationProcessingResult()
    result.cancelledRequestIDs = cancel(evaluation.cancellationRequestIDs)

    var latestError: String?
    for request in evaluation.requests {
      guard isCurrent() else { break }
      guard deliveryIsEnabled(for: request) else { continue }
      inFlightRequestIDs.insert(request.requestID)
      do {
        defer { inFlightRequestIDs.remove(request.requestID) }
        try await center.add(request)
        let current = isCurrent()
        guard current, deliveryIsEnabled(for: request) else {
          center.removeRequests(withIdentifiers: [request.requestID])
          result.cancelledRequestIDs.append(request.requestID)
          if !current {
            break
          }
          continue
        }
        policy.recordSuccess(for: request)
        if request.kind == .weeklyReset {
          scheduledRequestRevision &+= 1
        }
        persistLedger()
        result.acceptedRequestIDs.append(request.requestID)
      } catch {
        guard isCurrent() else { break }
        latestError = error.localizedDescription
        result.failedRequestIDs.append(request.requestID)
      }
    }
    result.cancelledRequestIDs = Array(Set(result.cancelledRequestIDs)).sorted()
    if isCurrent() {
      lastError = latestError
    }
    return result
  }

  enum PersistenceKey {
    static let preferences = "quotaNotification.preferences.v1"
    static let ledger = "quotaNotification.ledger.v1"
  }

  @discardableResult
  func cancelScheduled(
    where shouldCancel: (QuotaNotificationWindowKey) -> Bool
  ) -> [String] {
    let identifiers = policy.ledger.windows
      .filter { shouldCancel($0.key) }
      .compactMap(\.value.scheduledReset?.requestID)
      .sorted()
    return cancel(identifiers)
  }

  func cancel(_ identifiers: [String]) -> [String] {
    let identifiers = Array(Set(identifiers)).sorted()
    guard !identifiers.isEmpty else { return [] }
    center.removePendingRequests(withIdentifiers: identifiers)
    for identifier in identifiers {
      policy.recordCancellationSuccess(requestID: identifier)
    }
    persistLedger()
    return identifiers
  }

  func persistPreferences() {
    Self.save(preferences, key: PersistenceKey.preferences, defaults: defaults)
  }

  func persistLedger() {
    Self.save(policy.ledger, key: PersistenceKey.ledger, defaults: defaults)
  }

  static func load<Value: Decodable>(
    _ type: Value.Type,
    key: String,
    defaults: UserDefaults
  ) -> Value? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  static func save(
    _ value: some Encodable,
    key: String,
    defaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  static func normalized(
    _ preferences: QuotaNotificationPreferences
  ) -> QuotaNotificationPreferences {
    var preferences = preferences
    preferences.warningThreshold = min(max(preferences.warningThreshold, 1), 99)
    preferences.criticalThreshold = min(
      max(preferences.criticalThreshold, preferences.warningThreshold + 1),
      100
    )
    return preferences
  }

  func deliveryIsEnabled(for provider: UsageProvider) -> Bool {
    preferences.isEnabled && preferences.enabledProviders.contains(provider)
  }

  func deliveryIsEnabled(for request: QuotaNotificationRequest) -> Bool {
    deliveryIsEnabled(for: request.key.provider)
      && scopeAllows(
        provider: request.key.provider,
        logicalAccountID: request.key.logicalAccountID
      )
  }

  func scopeAllows(provider: UsageProvider, logicalAccountID: String) -> Bool {
    !scopedProviders.contains(provider)
      || activeLogicalAccountIDs[provider] == logicalAccountID
  }

  func reconcilePendingRequests() async {
    let revision = scheduledRequestRevision
    let actual = await center.pendingScheduledRequestIdentifiers()
    let journaled = Set(policy.ledger.windows.values.compactMap(\.scheduledReset?.requestID))
    let protected = journaled.union(inFlightRequestIDs)
    let missing = revision == scheduledRequestRevision
      ? journaled.subtracting(actual)
      : []
    for identifier in missing {
      policy.recordCancellationSuccess(requestID: identifier)
    }
    let orphaned = actual.filter {
      $0.hasPrefix("quotari.quota.") && !protected.contains($0)
    }
    if !orphaned.isEmpty {
      center.removePendingRequests(withIdentifiers: orphaned.sorted())
    }
    if !missing.isEmpty {
      persistLedger()
    }
  }
}
