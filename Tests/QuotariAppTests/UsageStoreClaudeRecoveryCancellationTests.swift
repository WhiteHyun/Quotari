import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ClaudeRecoveryCancellationTests {
  @Test(arguments: AutomaticCLIRecoveryIOGate.Point.allCases)
  func disablingClaudeStopsRecoveryAfterBlockedIO(point: AutomaticCLIRecoveryIOGate.Point) async throws {
    let gate = AutomaticCLIRecoveryIOGate(point: point)
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .mirror, recoveryGate: gate)
    let original = fixture.slot.value
    let reload = Task { await fixture.store.reloadAccounts() }
    await gate.waitUntilBlocked()

    fixture.store.setProviderEnabled(.claude, enabled: false)
    gate.resume()
    await reload.value

    if point == .afterKeychainWrite || point == .mirrorKeychainRead {
      #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    } else {
      #expect(fixture.slot.value == original)
    }
    #expect(try Data(contentsOf: fixture.fileURL) == original)
    #expect(!fixture.store.isProviderEnabled(.claude))
    #expect(!fixture.store.automaticallyCapturingProviders.contains(.claude))
    #expect(fixture.store.claudeCLIRecoveryTask == nil)
  }

  @Test func reEnablingClaudeCannotReviveTheCancelledRecoveryTask() async throws {
    let gate = AutomaticCLIRecoveryIOGate(point: .keychainRead)
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .mirror, recoveryGate: gate)
    let reload = Task { await fixture.store.reloadAccounts() }
    await gate.waitUntilBlocked()
    let operation = try #require(fixture.store.claudeCLIRecoveryTask)

    fixture.store.setProviderEnabled(.claude, enabled: false)
    fixture.store.setProviderEnabled(.claude, enabled: true)
    #expect(operation.isCancelled)
    gate.resume()

    do {
      _ = try await operation.value
      Issue.record("The original recovery must remain cancelled after re-enabling")
    } catch is CancellationError {
      // A later reload may recover; this generation must never write.
    }
    await reload.value
    await fixture.store.selectionRefreshTasks[.claude]?.value
  }
}

/// Pauses only injected synchronous recovery I/O, never the main actor.
final class AutomaticCLIRecoveryIOGate: @unchecked Sendable {
  enum Point: CaseIterable, Sendable {
    case processCheck, keychainRead, afterKeychainWrite, mirrorKeychainRead
  }

  private let point: Point
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var calls = 0
  private var blocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(point: Point) {
    self.point = point
  }

  func block(_ checkpoint: Point) {
    guard checkpoint == point || (point == .mirrorKeychainRead && checkpoint == .keychainRead) else { return }
    let shouldBlock = lock.withLock {
      calls += 1
      let targetCall = point == .mirrorKeychainRead ? 4 : (point == .afterKeychainWrite ? 1 : 2)
      return calls == targetCall
    }
    guard shouldBlock else { return }
    let pending = lock.withLock {
      blocked = true
      defer { waiters.removeAll() }
      return waiters
    }
    pending.forEach { $0.resume() }
    _ = release.wait(timeout: .now() + 10)
  }

  func waitUntilBlocked() async {
    await withCheckedContinuation { continuation in
      let alreadyBlocked = lock.withLock {
        if blocked {
          return true
        }
        waiters.append(continuation)
        return false
      }
      if alreadyBlocked {
        continuation.resume()
      }
    }
  }

  func resume() {
    release.signal()
  }
}
