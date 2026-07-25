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

  @Test func registryDoesNotRecursivelyWatchAnExcludedBroadAncestor() throws {
    let fixture = try ObservationDirectoryFixture(createsSessions: false)
    defer { fixture.remove() }
    let key = UsageInsightsObservationKey(provider: .codex, credentialScopeID: nil)
    let registry = UsageInsightsObservationRegistry(
      observations: [
        UsageInsightsLogObservation(key: key, roots: [fixture.sessions]),
      ],
      excludedAncestorPaths: [fixture.root.path]
    )

    #expect(registry.watchPaths.isEmpty)
  }

  @Test func registryReResolvesARetargetedSymlink() throws {
    let fixture = try SymlinkObservationFixture()
    defer { fixture.remove() }
    let key = UsageInsightsObservationKey(provider: .codex, credentialScopeID: nil)
    let observation = UsageInsightsLogObservation(
      key: key,
      roots: [fixture.link.appendingPathComponent("sessions", isDirectory: true)]
    )
    let first = UsageInsightsObservationRegistry(observations: [observation])

    try fixture.retargetLink()
    let second = UsageInsightsObservationRegistry(observations: [observation])

    #expect(first != second)
    #expect(second.watchPaths.contains(fixture.secondSessions.path))
    #expect(second.affectedKeys(
      path: fixture.secondSessions.appendingPathComponent("session.jsonl").path,
      flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
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

  @Test func monitorReconcilesARetargetedSymlinkAndInvalidatesItsScope() async throws {
    let fixture = try SymlinkObservationFixture()
    defer { fixture.remove() }
    let key = UsageInsightsObservationKey(provider: .codex, credentialScopeID: nil)
    let capture = UsageInsightsChangeCapture()
    let monitor = FSEventsUsageInsightsChangeMonitor(
      quietPeriod: .milliseconds(20),
      maximumDelay: .milliseconds(100),
      reconciliationInterval: .milliseconds(20)
    )
    defer { monitor.stop() }
    monitor.replaceObservations([
      UsageInsightsLogObservation(
        key: key,
        roots: [fixture.link.appendingPathComponent("sessions", isDirectory: true)]
      ),
    ]) { keys in
      capture.record(keys)
    }
    try await Task.sleep(for: .milliseconds(100))

    try fixture.retargetLink()

    for _ in 0 ..< 200 {
      if capture.keys.contains(key) {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(capture.keys.contains(key))
  }

  @Test func replacingObservationsDeliversPendingChangesToThePreviousCallback() {
    let oldKey = UsageInsightsObservationKey(provider: .codex, credentialScopeID: nil)
    let newKey = UsageInsightsObservationKey(provider: .claude, credentialScopeID: nil)
    let oldCapture = UsageInsightsChangeCapture()
    let monitor = FSEventsUsageInsightsChangeMonitor(
      quietPeriod: .seconds(10),
      maximumDelay: .seconds(10)
    )
    defer { monitor.stop() }
    monitor.replaceObservations([]) { keys in
      oldCapture.record(keys)
    }
    monitor.recordChanges([oldKey])

    monitor.replaceObservations([
      UsageInsightsLogObservation(key: newKey, roots: []),
    ]) { _ in }
    monitor.recordChanges([])

    #expect(oldCapture.keys == [oldKey])
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

private struct SymlinkObservationFixture {
  let root: URL
  let link: URL
  let firstSessions: URL
  let secondSessions: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-symlink-observer-\(UUID().uuidString)", isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    firstSessions = first.appendingPathComponent("sessions", isDirectory: true)
    secondSessions = second.appendingPathComponent("sessions", isDirectory: true)
    link = root.appendingPathComponent("current", isDirectory: true)
    try FileManager.default.createDirectory(at: firstSessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondSessions, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
  }

  func retargetLink() throws {
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: secondSessions.deletingLastPathComponent()
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
