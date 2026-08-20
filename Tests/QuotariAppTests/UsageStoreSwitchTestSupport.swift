import Foundation
@testable import QuotariCore

final class AppCredentialLifecycleEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CredentialLifecycleEvent] = []

  var events: [CredentialLifecycleEvent] {
    lock.withLock { storage }
  }

  var logger: CredentialLifecycleLogger {
    CredentialLifecycleLogger(
      record: { [weak self] event in
        guard let self else { return }
        lock.withLock { self.storage.append(event) }
      },
      opaqueAccountID: { "opaque:\($0)" },
      now: { Date(timeIntervalSince1970: 1_783_478_400) }
    )
  }
}

actor GatedSwitchDiscovery: ProviderAccountDiscovering {
  private let beforeSwitch: StaticAccountDiscovery
  private let afterSwitch: StaticAccountDiscovery
  private let writtenCredentialURL: URL?
  private let preWriteRequestCount: Int
  private var accountRequests = 0
  private(set) var postSwitchRequestSawCredential: Bool?
  private var switchReloadStarted = false
  private var reloadMayContinue = false
  private var switchReloadWaiters: [CheckedContinuation<Void, Never>] = []
  private var reloadContinuation: CheckedContinuation<Void, Never>?

  init(
    beforeSwitch: StaticAccountDiscovery,
    afterSwitch: StaticAccountDiscovery,
    writtenCredentialURL: URL? = nil,
    preWriteRequestCount: Int = 1
  ) {
    self.beforeSwitch = beforeSwitch
    self.afterSwitch = afterSwitch
    self.writtenCredentialURL = writtenCredentialURL
    self.preWriteRequestCount = preWriteRequestCount
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
    if let writtenCredentialURL, accountRequests == preWriteRequestCount + 1 {
      postSwitchRequestSawCredential = FileManager.default.fileExists(
        atPath: writtenCredentialURL.path
      )
    }
    let discovery = accountRequests <= preWriteRequestCount ? beforeSwitch : afterSwitch
    return await discovery.accounts(for: provider)
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    let discovery = accountRequests <= preWriteRequestCount ? beforeSwitch : afterSwitch
    return await discovery.liveAccount(equivalentTo: account, among: accounts)
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    let discovery = accountRequests <= preWriteRequestCount ? beforeSwitch : afterSwitch
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
