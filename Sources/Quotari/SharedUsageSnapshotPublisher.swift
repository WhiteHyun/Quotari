import Foundation
import QuotariCore
import QuotariSharedSnapshot

/// Writes the usage snapshot other tools read (ADR 0003) whenever its contents
/// change.
@MainActor
final class SharedUsageSnapshotPublisher {
  var file = SharedUsageSnapshotFile()
  private var published: [SharedUsageSnapshot.Provider]?

  func publish(_ providers: [SharedUsageSnapshot.Provider], now: Date) {
    guard providers != published else { return }
    published = providers
    try? file.write(SharedUsageSnapshot(generatedAt: now, providers: providers))
  }
}

extension SharedUsageSnapshot.Provider {
  /// Plan and windows only: the account's name, email, and credentials stay in
  /// the app.
  init(descriptor: ProviderDescriptor, usage: UsageSnapshot) {
    let windows = [usage.primary, usage.secondary].compactMap(\.self).map { SharedUsageSnapshot.Window($0) }
      + usage.extraWindows.map { SharedUsageSnapshot.Window($0.window, label: $0.title) }
    self.init(
      id: descriptor.id.rawValue,
      name: descriptor.metadata.displayName,
      plan: usage.plan,
      updatedAt: usage.updatedAt,
      windows: windows
    )
  }
}

extension SharedUsageSnapshot.Window {
  init(_ window: RateWindow, label: String? = nil) {
    self.init(
      kind: window.kind.rawValue,
      label: label ?? window.label,
      usedPercent: window.usedPercent,
      resetsAt: window.resetsAt,
      durationSeconds: window.duration
    )
  }
}

extension UsageStore {
  /// The dashboard's readings for each enabled provider.
  func publishSharedUsageSnapshot() {
    let providers = enabledProviderDescriptors.compactMap { descriptor in
      snapshots[descriptor.id].map { SharedUsageSnapshot.Provider(descriptor: descriptor, usage: $0) }
    }
    sharedUsageSnapshotPublisher.publish(providers, now: currentDate())
  }
}
