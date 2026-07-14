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
