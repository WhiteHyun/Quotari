import CoreServices
import Foundation
import QuotariCore

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

final class FSEventsUsageInsightsChangeMonitor: UsageInsightsChangeMonitoring, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.whitehyun.Quotari.usage-insights-events")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let quietPeriod: UInt64
  private let maximumDelay: UInt64
  private let reconciliationInterval: UInt64
  private let streamStartGate: (@Sendable () -> Bool)?
  private var stream: FSEventStreamRef?
  private var observations: [UsageInsightsLogObservation] = []
  private var registry = UsageInsightsObservationRegistry(observations: [])
  private var onChange: (@Sendable (Set<UsageInsightsObservationKey>) -> Void)?
  private var batchPolicy = UsageInsightsEventBatchPolicy()
  private var batchGeneration: UInt64 = 0
  private var batchWorkItem: DispatchWorkItem?
  private var reconciliationGeneration: UInt64 = 0
  private var reconciliationWorkItem: DispatchWorkItem?

  init(
    quietPeriod: Duration = .seconds(2),
    maximumDelay: Duration = .seconds(30),
    reconciliationInterval: Duration = .seconds(30),
    streamStartGate: (@Sendable () -> Bool)? = nil
  ) {
    self.quietPeriod = quietPeriod.nanosecondsClamped
    self.maximumDelay = max(self.quietPeriod, maximumDelay.nanosecondsClamped)
    self.reconciliationInterval = max(1, reconciliationInterval.nanosecondsClamped)
    self.streamStartGate = streamStartGate
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    performOnQueueSynchronously {
      tearDownMonitoring()
    }
  }

  func replaceObservations(
    _ observations: [UsageInsightsLogObservation],
    onChange: @escaping @Sendable (Set<UsageInsightsObservationKey>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      if self.observations == observations {
        self.onChange = onChange
        reconcileRegistry()
        return
      }
      let pendingKeys = takePendingChanges()
      let previousOnChange = self.onChange
      let nextRegistry = UsageInsightsObservationRegistry(observations: observations)
      let retainedKeys = registry.allKeys.intersection(nextRegistry.allKeys)
      cancelReconciliation()
      stopStream()
      previousOnChange?(pendingKeys)
      self.observations = observations
      registry = nextRegistry
      self.onChange = onChange
      startStream()
      scheduleReconciliation()
      if !retainedKeys.isEmpty {
        onChange(retainedKeys)
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.tearDownMonitoring()
    }
  }

  @discardableResult
  private func startStream() -> Bool {
    guard stream == nil else { return true }
    guard !registry.watchPaths.isEmpty,
          streamStartGate?() != false
    else { return false }
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
    ) else { return false }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return false
    }
    return true
  }

  private func stopStream() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  private func tearDownMonitoring() {
    cancelReconciliation()
    _ = takePendingChanges()
    stopStream()
    observations = []
    registry = UsageInsightsObservationRegistry(observations: [])
    onChange = nil
  }

  private func takePendingChanges() -> Set<UsageInsightsObservationKey> {
    batchWorkItem?.cancel()
    batchWorkItem = nil
    batchGeneration &+= 1
    return batchPolicy.flush()
  }

  private func reconcileRegistry() {
    let nextRegistry = UsageInsightsObservationRegistry(observations: observations)
    guard nextRegistry != registry else {
      if stream == nil, startStream(), !registry.allKeys.isEmpty {
        onChange?(registry.allKeys)
      }
      return
    }
    let affectedKeys = takePendingChanges()
      .union(registry.allKeys)
      .union(nextRegistry.allKeys)
    stopStream()
    registry = nextRegistry
    startStream()
    guard !affectedKeys.isEmpty else { return }
    onChange?(affectedKeys)
  }

  private func scheduleReconciliation() {
    guard !observations.isEmpty else { return }
    reconciliationGeneration &+= 1
    let generation = reconciliationGeneration
    let workItem = DispatchWorkItem { [weak self] in
      self?.reconcileAndReschedule(generation: generation)
    }
    reconciliationWorkItem = workItem
    let now = DispatchTime.now().uptimeNanoseconds
    queue.asyncAfter(
      deadline: DispatchTime(uptimeNanoseconds: now.addingClamped(reconciliationInterval)),
      execute: workItem
    )
  }

  private func reconcileAndReschedule(generation: UInt64) {
    guard generation == reconciliationGeneration else { return }
    reconciliationWorkItem = nil
    reconcileRegistry()
    scheduleReconciliation()
  }

  private func cancelReconciliation() {
    reconciliationWorkItem?.cancel()
    reconciliationWorkItem = nil
    reconciliationGeneration &+= 1
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
    recordChanges(keys)
  }

  func recordChanges(_ keys: Set<UsageInsightsObservationKey>) {
    performOnQueueSynchronously {
      guard !keys.isEmpty else { return }
      enqueue(keys)
    }
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
