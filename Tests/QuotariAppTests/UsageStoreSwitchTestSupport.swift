import Foundation
@testable import QuotariCore

actor GatedSwitchDiscovery: ProviderAccountDiscovering {
  private let beforeSwitch: StaticAccountDiscovery
  private let afterSwitch: StaticAccountDiscovery
  private var accountRequests = 0
  private var switchReloadStarted = false
  private var reloadMayContinue = false
  private var switchReloadWaiters: [CheckedContinuation<Void, Never>] = []
  private var reloadContinuation: CheckedContinuation<Void, Never>?

  init(beforeSwitch: StaticAccountDiscovery, afterSwitch: StaticAccountDiscovery) {
    self.beforeSwitch = beforeSwitch
    self.afterSwitch = afterSwitch
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    accountRequests += 1
    if accountRequests == 2 {
      switchReloadStarted = true
      let waiters = switchReloadWaiters
      switchReloadWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      if !reloadMayContinue {
        await withCheckedContinuation { continuation in
          reloadContinuation = continuation
        }
      }
    }
    let discovery = accountRequests == 1 ? beforeSwitch : afterSwitch
    return await discovery.accounts(for: provider)
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    let discovery = accountRequests == 1 ? beforeSwitch : afterSwitch
    return await discovery.liveAccount(equivalentTo: account, among: accounts)
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    let discovery = accountRequests == 1 ? beforeSwitch : afterSwitch
    return await discovery.capturedCopies(among: accounts)
  }

  func waitUntilSwitchReloadStarts() async {
    guard !switchReloadStarted else { return }
    await withCheckedContinuation { continuation in
      switchReloadWaiters.append(continuation)
    }
  }

  func resumeSwitchReload() {
    reloadMayContinue = true
    reloadContinuation?.resume()
    reloadContinuation = nil
  }
}
