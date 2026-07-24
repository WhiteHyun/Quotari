import CoreServices
import Foundation
import QuotariCore

struct UsageInsightsObservationKey: Hashable, Sendable {
  let provider: UsageProvider
  let credentialScopeID: String?
}

struct UsageInsightsLogObservation: Equatable, Sendable {
  let key: UsageInsightsObservationKey
  let roots: [URL]
}

protocol UsageInsightsChangeMonitoring: AnyObject, Sendable {
  func replaceObservations(
    _ observations: [UsageInsightsLogObservation],
    onChange: @escaping @Sendable (Set<UsageInsightsObservationKey>) -> Void
  )
  func stop()
}

final class DisabledUsageInsightsChangeMonitor: UsageInsightsChangeMonitoring, @unchecked Sendable {
  func replaceObservations(
    _: [UsageInsightsLogObservation],
    onChange _: @escaping @Sendable (Set<UsageInsightsObservationKey>) -> Void
  ) {}

  func stop() {}
}

struct UsageInsightsEventBatchPolicy {
  private(set) var pendingKeys = Set<UsageInsightsObservationKey>()
  private(set) var burstStartedAt: UInt64?

  mutating func record(
    _ keys: Set<UsageInsightsObservationKey>,
    now: UInt64,
    quietPeriod: UInt64,
    maximumDelay: UInt64
  ) -> UInt64 {
    if burstStartedAt == nil {
      burstStartedAt = now
    }
    pendingKeys.formUnion(keys)
    let maximumDeadline = (burstStartedAt ?? now).addingClamped(maximumDelay)
    return min(now.addingClamped(quietPeriod), maximumDeadline)
  }

  mutating func flush() -> Set<UsageInsightsObservationKey> {
    defer {
      pendingKeys.removeAll()
      burstStartedAt = nil
    }
    return pendingKeys
  }
}

struct UsageInsightsObservationRegistry {
  private struct Entry {
    let key: UsageInsightsObservationKey
    let rootPath: String
  }

  private let entries: [Entry]
  let watchPaths: [String]

  init(
    observations: [UsageInsightsLogObservation],
    fileManager: FileManager = .default
  ) {
    var entries: [Entry] = []
    var watchPaths = Set<String>()
    var seenEntries = Set<String>()

    for observation in observations {
      for root in observation.roots {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let identity = "\(observation.key.provider.rawValue)\u{0}\(observation.key.credentialScopeID ?? "")\u{0}\(rootPath)"
        guard seenEntries.insert(identity).inserted else { continue }
        entries.append(Entry(key: observation.key, rootPath: rootPath))
        if let watchPath = Self.nearestExistingDirectory(
          for: URL(fileURLWithPath: rootPath, isDirectory: true),
          fileManager: fileManager
        ) {
          watchPaths.insert(watchPath)
        }
      }
    }

    self.entries = entries
    self.watchPaths = watchPaths.sorted()
  }

  func affectedKeys(path: String, flags: FSEventStreamEventFlags) -> Set<UsageInsightsObservationKey> {
    let droppedFlags = kFSEventStreamEventFlagMustScanSubDirs
      | kFSEventStreamEventFlagUserDropped
      | kFSEventStreamEventFlagKernelDropped
    if flags & FSEventStreamEventFlags(droppedFlags) != 0 {
      return Set(entries.map(\.key))
    }
    let path = URL(fileURLWithPath: path).standardizedFileURL.path
    guard Self.isRelevant(path: path, flags: flags) else { return [] }
    return Set(entries.compactMap { entry in
      Self.pathsOverlap(path, entry.rootPath) ? entry.key : nil
    })
  }

  private static func isRelevant(path: String, flags: FSEventStreamEventFlags) -> Bool {
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
      return true
    }
    if flags == 0 || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
      return true
    }
    let mutationFlags = kFSEventStreamEventFlagItemCreated
      | kFSEventStreamEventFlagItemRemoved
      | kFSEventStreamEventFlagItemRenamed
      | kFSEventStreamEventFlagItemModified
    return path.lowercased().hasSuffix(".jsonl")
      && flags & FSEventStreamEventFlags(mutationFlags) != 0
  }

  private static func pathsOverlap(_ eventPath: String, _ rootPath: String) -> Bool {
    eventPath == rootPath
      || eventPath.hasPrefix(rootPath + "/")
      || rootPath.hasPrefix(eventPath + "/")
  }

  private static func nearestExistingDirectory(
    for url: URL,
    fileManager: FileManager
  ) -> String? {
    var candidate = url
    while true {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
         isDirectory.boolValue {
        return candidate.path
      }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path != candidate.path else { return nil }
      candidate = parent
    }
  }
}

final class FSEventsUsageInsightsChangeMonitor: UsageInsightsChangeMonitoring, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.whitehyun.Quotari.usage-insights-events")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let quietPeriod: UInt64
  private let maximumDelay: UInt64
  private var stream: FSEventStreamRef?
  private var registry = UsageInsightsObservationRegistry(observations: [])
  private var onChange: (@Sendable (Set<UsageInsightsObservationKey>) -> Void)?
  private var batchPolicy = UsageInsightsEventBatchPolicy()
  private var batchGeneration: UInt64 = 0
  private var batchWorkItem: DispatchWorkItem?

  init(
    quietPeriod: Duration = .seconds(2),
    maximumDelay: Duration = .seconds(30)
  ) {
    self.quietPeriod = quietPeriod.nanosecondsClamped
    self.maximumDelay = max(self.quietPeriod, maximumDelay.nanosecondsClamped)
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    performOnQueueSynchronously {
      tearDownStream()
    }
  }

  func replaceObservations(
    _ observations: [UsageInsightsLogObservation],
    onChange: @escaping @Sendable (Set<UsageInsightsObservationKey>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      tearDownStream()
      registry = UsageInsightsObservationRegistry(observations: observations)
      self.onChange = onChange
      startStream()
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.tearDownStream()
    }
  }

  private func startStream() {
    guard !registry.watchPaths.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagWatchRoot
        | kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer
    )
    guard let stream = FSEventStreamCreate(
      nil,
      Self.eventCallback,
      &context,
      registry.watchPaths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.2,
      flags
    ) else { return }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return
    }
  }

  private func tearDownStream() {
    batchWorkItem?.cancel()
    batchWorkItem = nil
    _ = batchPolicy.flush()
    batchGeneration &+= 1
    onChange = nil
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  private func receive(
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    count: Int
  ) {
    let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    var keys = Set<UsageInsightsObservationKey>()
    for index in 0 ..< count {
      guard let rawPath = paths[index] else { continue }
      keys.formUnion(registry.affectedKeys(
        path: String(cString: rawPath),
        flags: eventFlags[index]
      ))
    }
    guard !keys.isEmpty else { return }
    enqueue(keys)
  }

  private func enqueue(_ keys: Set<UsageInsightsObservationKey>) {
    let now = DispatchTime.now().uptimeNanoseconds
    let deadline = batchPolicy.record(
      keys,
      now: now,
      quietPeriod: quietPeriod,
      maximumDelay: maximumDelay
    )
    batchWorkItem?.cancel()
    batchGeneration &+= 1
    let generation = batchGeneration
    let workItem = DispatchWorkItem { [weak self] in
      self?.flush(generation: generation)
    }
    batchWorkItem = workItem
    queue.asyncAfter(
      deadline: DispatchTime(uptimeNanoseconds: deadline),
      execute: workItem
    )
  }

  private func flush(generation: UInt64) {
    guard generation == batchGeneration else { return }
    batchWorkItem = nil
    let keys = batchPolicy.flush()
    guard !keys.isEmpty else { return }
    onChange?(keys)
  }

  private func performOnQueueSynchronously(_ operation: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      operation()
    } else {
      queue.sync(execute: operation)
    }
  }

  private static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
    guard let info else { return }
    Unmanaged<FSEventsUsageInsightsChangeMonitor>
      .fromOpaque(info)
      .takeUnretainedValue()
      .receive(eventPaths: eventPaths, eventFlags: eventFlags, count: count)
  }
}

private extension UInt64 {
  func addingClamped(_ value: UInt64) -> UInt64 {
    let (sum, overflow) = addingReportingOverflow(value)
    return overflow ? .max : sum
  }
}

private extension Duration {
  var nanosecondsClamped: UInt64 {
    let components = components
    guard components.seconds >= 0 else { return 0 }
    let seconds = UInt64(clamping: components.seconds)
    let secondsInNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !secondsInNanoseconds.overflow else { return .max }
    let attoseconds = max(0, components.attoseconds)
    let remainder = UInt64(attoseconds / 1_000_000_000)
    return secondsInNanoseconds.partialValue.addingClamped(remainder)
  }
}
