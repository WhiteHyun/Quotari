import Foundation

final class CredentialLifecycleLogRuntime: @unchecked Sendable {
  private static let maintenanceInterval = 24 * 60 * 60

  private let store: CredentialLifecycleLogStore
  private let queue: DispatchQueue
  private let maintenanceTimer: DispatchSourceTimer

  init(store: CredentialLifecycleLogStore) {
    self.store = store
    queue = DispatchQueue(
      label: "com.quotari.QuotariCore.credential-lifecycle",
      qos: .utility
    )
    maintenanceTimer = DispatchSource.makeTimerSource(queue: queue)
    maintenanceTimer.schedule(
      deadline: .now(),
      repeating: .seconds(Self.maintenanceInterval),
      leeway: .seconds(5 * 60)
    )
    maintenanceTimer.setEventHandler { [store] in
      try? store.performMaintenance()
    }
    maintenanceTimer.resume()
  }

  deinit {
    maintenanceTimer.cancel()
  }

  func record(_ event: CredentialLifecycleEvent) {
    queue.async { [store] in
      try? store.record(event)
    }
  }

  func prepareLogForAccess() async -> URL {
    await withCheckedContinuation { continuation in
      queue.async { [store] in
        let url = (try? store.prepareLogForAccess()) ?? store.url
        continuation.resume(returning: url)
      }
    }
  }
}
