import Foundation
@testable import Quotari
@testable import QuotariCore

actor GatedInitialAccountDiscovery: ProviderAccountDiscovering {
  let account: ProviderAccount
  private var reloadStarted = false
  private var reloadStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var reloadContinuation: CheckedContinuation<Void, Never>?

  init(account: ProviderAccount) {
    self.account = account
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    reloadStarted = true
    let waiters = reloadStartWaiters
    reloadStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      reloadContinuation = continuation
    }
    return provider == account.provider ? [account] : []
  }

  func waitUntilReloadStarts() async {
    guard !reloadStarted else { return }
    await withCheckedContinuation { continuation in
      reloadStartWaiters.append(continuation)
    }
  }

  func resumeReload() {
    reloadContinuation?.resume()
    reloadContinuation = nil
  }
}

actor GatedNotificationUsageStrategy: ProviderFetchStrategy {
  let snapshot: UsageSnapshot
  let id = "gated-notification-usage"
  let kind = ProviderFetchKind.api
  private var requestCount = 0
  private var requestStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstRequestContinuation: CheckedContinuation<Void, Never>?

  init(snapshot: UsageSnapshot) {
    self.snapshot = snapshot
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let isFirstRequest = requestCount == 0
    requestCount += 1
    if isFirstRequest {
      let waiters = requestStartWaiters
      requestStartWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        firstRequestContinuation = continuation
      }
    }
    return ProviderFetchResult(usage: snapshot, sourceLabel: "Live")
  }

  func waitUntilFirstRequestStarts() async {
    guard requestCount == 0 else { return }
    await withCheckedContinuation { continuation in
      requestStartWaiters.append(continuation)
    }
  }

  func resumeFirstRequest() {
    firstRequestContinuation?.resume()
    firstRequestContinuation = nil
  }
}

@MainActor
struct UsageNotificationHarness {
  var store: UsageStore
  var controller: QuotaNotificationController
  var center: UsageNotificationCenterStub
}

@MainActor
final class UsageNotificationCenterStub: QuotaNotificationCenterTransport {
  var attemptedRequests: [QuotaNotificationRequest] = []
  private(set) var pendingIDs: Set<String> = []
  private(set) var deliveredIDs: Set<String> = []
  var authorizationGate: UsageNotificationQueueGate?
  var addGate: UsageNotificationQueueGate?
  var addError: Error?

  func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
    await authorizationGate?.wait()
    return .authorized
  }

  func requestAuthorization() async throws -> Bool {
    true
  }

  func pendingScheduledRequestIdentifiers() async -> Set<String> {
    pendingIDs
  }

  func add(_ request: QuotaNotificationRequest) async throws {
    attemptedRequests.append(request)
    await addGate?.wait()
    if let addError {
      throw addError
    }
    if request.kind == .weeklyReset {
      pendingIDs.insert(request.requestID)
    } else {
      deliveredIDs.insert(request.requestID)
    }
  }

  func removePendingRequests(withIdentifiers identifiers: [String]) {
    pendingIDs.subtract(identifiers)
  }

  func removeRequests(withIdentifiers identifiers: [String]) {
    pendingIDs.subtract(identifiers)
    deliveredIDs.subtract(identifiers)
  }

  func configureForegroundPresentation() {}
}

actor UsageNotificationQueueGate {
  private var isReleased = false
  private var hasWaiter = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    hasWaiter = true
    arrivalWaiters.forEach { $0.resume() }
    arrivalWaiters.removeAll()
    guard !isReleased else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func waitUntilBlocked() async {
    guard !hasWaiter else { return }
    await withCheckedContinuation { arrivalWaiters.append($0) }
  }

  func release() {
    isReleased = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}
