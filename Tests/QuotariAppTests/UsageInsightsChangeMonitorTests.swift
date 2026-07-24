import CoreServices
import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

struct UsageInsightsChangeMonitorTests {
  @Test func registryRoutesCreateWriteRenameAndDeleteEventsToTheirScope() throws {
    let fixture = try ObservationDirectoryFixture()
    defer { fixture.remove() }
    let key = UsageInsightsObservationKey(provider: .codex, credentialScopeID: "codex:account")
    let registry = UsageInsightsObservationRegistry(observations: [
      UsageInsightsLogObservation(key: key, roots: [fixture.sessions]),
    ])
    let log = fixture.sessions.appendingPathComponent("nested/session.jsonl").path

    for flag in [
      kFSEventStreamEventFlagItemCreated,
      kFSEventStreamEventFlagItemModified,
      kFSEventStreamEventFlagItemRenamed,
      kFSEventStreamEventFlagItemRemoved,
    ] {
      #expect(registry.affectedKeys(path: log, flags: FSEventStreamEventFlags(flag)) == [key])
    }
    #expect(registry.affectedKeys(
      path: fixture.sessions.appendingPathComponent("notes.txt").path,
      flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
    ).isEmpty)
    #expect(registry.affectedKeys(
      path: fixture.root.appendingPathComponent("unrelated/session.jsonl").path,
      flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
    ).isEmpty)
  }

  @Test func registryWatchesExistingAncestorAndRoutesFutureRootCreation() throws {
    let fixture = try ObservationDirectoryFixture(createsSessions: false)
    defer { fixture.remove() }
    let key = UsageInsightsObservationKey(provider: .claude, credentialScopeID: nil)
    let registry = UsageInsightsObservationRegistry(observations: [
      UsageInsightsLogObservation(key: key, roots: [fixture.sessions]),
    ])

    #expect(registry.watchPaths == [fixture.root.path])
    #expect(registry.affectedKeys(
      path: fixture.sessions.path,
      flags: FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir
      )
    ) == [key])
  }

  @Test func droppedEventInvalidatesEveryObservedScope() throws {
    let fixture = try ObservationDirectoryFixture()
    defer { fixture.remove() }
    let codex = UsageInsightsObservationKey(provider: .codex, credentialScopeID: nil)
    let claude = UsageInsightsObservationKey(provider: .claude, credentialScopeID: "claude:account")
    let registry = UsageInsightsObservationRegistry(observations: [
      UsageInsightsLogObservation(key: codex, roots: [fixture.sessions]),
      UsageInsightsLogObservation(
        key: claude,
        roots: [fixture.root.appendingPathComponent("claude", isDirectory: true)]
      ),
    ])

    #expect(registry.affectedKeys(
      path: "/",
      flags: FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped
      )
    ) == [codex, claude])
  }

  @Test func burstPolicyUsesQuietPeriodWithoutExceedingMaximumDelay() {
    let codex = UsageInsightsObservationKey(provider: .codex, credentialScopeID: nil)
    let claude = UsageInsightsObservationKey(provider: .claude, credentialScopeID: nil)
    var policy = UsageInsightsEventBatchPolicy()
    let second: UInt64 = 1_000_000_000

    #expect(policy.record([codex], now: 0, quietPeriod: 2 * second, maximumDelay: 30 * second) == 2 * second)
    #expect(policy.record(
      [claude],
      now: 1 * second,
      quietPeriod: 2 * second,
      maximumDelay: 30 * second
    ) == 3 * second)
    #expect(policy.record(
      [codex],
      now: 29 * second,
      quietPeriod: 2 * second,
      maximumDelay: 30 * second
    ) == 30 * second)
    #expect(policy.flush() == [codex, claude])
    #expect(policy.pendingKeys.isEmpty)
    #expect(policy.burstStartedAt == nil)
  }

  @Test func fseventsBackendReportsAJsonlWrite() async throws {
    let fixture = try ObservationDirectoryFixture()
    defer { fixture.remove() }
    let key = UsageInsightsObservationKey(provider: .codex, credentialScopeID: nil)
    let capture = UsageInsightsChangeCapture()
    let monitor = FSEventsUsageInsightsChangeMonitor(
      quietPeriod: .milliseconds(20),
      maximumDelay: .milliseconds(100)
    )
    defer { monitor.stop() }
    monitor.replaceObservations([
      UsageInsightsLogObservation(key: key, roots: [fixture.sessions]),
    ]) { keys in
      capture.record(keys)
    }
    try await Task.sleep(for: .milliseconds(200))

    let log = fixture.sessions.appendingPathComponent("session.jsonl")
    try Data("{\"type\":\"event\"}\n".utf8).write(to: log)

    for _ in 0 ..< 200 {
      if capture.keys.contains(key) {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(capture.keys.contains(key))
  }
}

private final class UsageInsightsChangeCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storedKeys = Set<UsageInsightsObservationKey>()

  var keys: Set<UsageInsightsObservationKey> {
    lock.withLock { storedKeys }
  }

  func record(_ keys: Set<UsageInsightsObservationKey>) {
    lock.withLock {
      storedKeys.formUnion(keys)
    }
  }
}

private struct ObservationDirectoryFixture {
  let root: URL
  let sessions: URL

  init(createsSessions: Bool = true) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-observer-\(UUID().uuidString)", isDirectory: true)
    sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(
      at: createsSessions ? sessions : root,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
