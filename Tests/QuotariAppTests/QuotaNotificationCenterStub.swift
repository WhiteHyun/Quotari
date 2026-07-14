import Foundation
@testable import Quotari
@testable import QuotariCore

@MainActor
final class QuotaNotificationCenterStub: QuotaNotificationCenterTransport {
  var status: QuotaNotificationAuthorizationStatus
  var grantsAuthorization = true
  var authorizationRequestCount = 0
  var failuresRemaining = 0
  var attemptedRequests: [QuotaNotificationRequest] = []
  var pendingScheduledIDs: Set<String> = []
  var deliveredIDs: Set<String> = []
  var removedRequestIDs: [[String]] = []
  var foregroundPresentationConfigured = false
  var suspendAdds = false
  var publishesScheduledBeforeSuspending = false
  private var suspendedAdds: [CheckedContinuation<Void, Never>] = []
  var suspendNextPendingQuery = false
  private var suspendedPendingQueries: [CheckedContinuation<Void, Never>] = []

  var suspendedAddCount: Int {
    suspendedAdds.count
  }

  init(status: QuotaNotificationAuthorizationStatus) {
    self.status = status
  }

  func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
    status
  }

  func requestAuthorization() async throws -> Bool {
    authorizationRequestCount += 1
    status = grantsAuthorization ? .authorized : .denied
    return grantsAuthorization
  }

  func pendingScheduledRequestIdentifiers() async -> Set<String> {
    let snapshot = pendingScheduledIDs
    if suspendNextPendingQuery {
      suspendNextPendingQuery = false
      await withCheckedContinuation { continuation in
        suspendedPendingQueries.append(continuation)
      }
    }
    return snapshot
  }

  func add(_ request: QuotaNotificationRequest) async throws {
    attemptedRequests.append(request)
    if request.kind == .weeklyReset, publishesScheduledBeforeSuspending {
      pendingScheduledIDs.insert(request.requestID)
    }
    if suspendAdds {
      await withCheckedContinuation { continuation in
        suspendedAdds.append(continuation)
      }
    }
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw DeliveryError()
    }
    if request.kind == .weeklyReset {
      pendingScheduledIDs.insert(request.requestID)
    } else {
      deliveredIDs.insert(request.requestID)
    }
  }

  func removePendingRequests(withIdentifiers identifiers: [String]) {
    removedRequestIDs.append(identifiers.sorted())
    pendingScheduledIDs.subtract(identifiers)
  }

  func removeRequests(withIdentifiers identifiers: [String]) {
    removePendingRequests(withIdentifiers: identifiers)
    deliveredIDs.subtract(identifiers)
  }

  func configureForegroundPresentation() {
    foregroundPresentationConfigured = true
  }

  func waitForSuspendedAdd() async {
    while suspendedAdds.isEmpty {
      await Task.yield()
    }
  }

  func resumeAdds() {
    suspendAdds = false
    let continuations = suspendedAdds
    suspendedAdds.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  func waitForSuspendedPendingQuery() async {
    while suspendedPendingQueries.isEmpty {
      await Task.yield()
    }
  }

  func resumePendingQueries() {
    let continuations = suspendedPendingQueries
    suspendedPendingQueries.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }
}

private struct DeliveryError: LocalizedError {
  var errorDescription: String? {
    "delivery failed"
  }
}
