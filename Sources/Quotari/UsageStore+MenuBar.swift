import AppKit
import QuotariCore

extension UsageStore {
  var highestUsedPercent: Double {
    enabledProviderDescriptors
      .compactMap { snapshots[$0.id]?.highestUsedPercent }
      .max() ?? 0
  }

  var menuBarUsedPercent: Double? {
    switch menuBarPreferences.preferences.usageSource {
    case .mostConstrained:
      return enabledProviderDescriptors
        .compactMap { snapshots[$0.id] }
        .compactMap { menuBarUsedPercent(for: $0) }
        .max()
    case let .provider(provider):
      guard isProviderEnabled(provider) else { return nil }
      return snapshots[provider].flatMap { menuBarUsedPercent(for: $0) }
    }
  }

  var menuBarRemainingPercent: Int? {
    menuBarUsedPercent.map { Int((100 - $0).rounded()) }
  }

  var menuBarRemainingText: String? {
    guard menuBarPreferences.preferences.showsRemainingPercent,
          let remaining = menuBarRemainingPercent
    else { return nil }
    return "\(remaining)%"
  }

  func menuBarIcon(frame: Int) -> NSImage {
    IconRenderer.mascotIcon(frame: frame)
  }

  var menuBarAnimationInterval: TimeInterval {
    IconRenderer.animationInterval(usedPercent: menuBarUsedPercent ?? 0)
  }

  var menuBarAccessibilityLabel: String {
    guard !enabledProviderDescriptors.isEmpty else {
      return L10n.string("Quotari, no providers enabled")
    }
    guard let usedPercent = menuBarUsedPercent,
          let remaining = menuBarRemainingPercent
    else {
      return switch menuBarPreferences.preferences.usageSource {
      case .mostConstrained:
        L10n.string("Quotari, loading usage")
      case let .provider(provider):
        L10n.string("Quotari, loading \(providerDisplayName(provider)) usage")
      }
    }
    let source = switch menuBarPreferences.preferences.usageSource {
    case .mostConstrained:
      L10n.string("lowest remaining quota")
    case let .provider(provider):
      L10n.string("\(providerDisplayName(provider)) remaining quota")
    }
    return L10n.string("Quotari, \(source) \(remaining) percent, \(Theme.statusWord(usedPercent))")
  }

  private func menuBarUsedPercent(for snapshot: UsageSnapshot) -> Double? {
    if let standardWindowPercent = [snapshot.primary?.usedPercent, snapshot.secondary?.usedPercent]
      .compactMap(\.self)
      .max() {
      return standardWindowPercent
    }
    return snapshot.extraWindows.map(\.window.usedPercent).max()
  }

  private func providerDisplayName(_ provider: UsageProvider) -> String {
    providers.first { $0.id == provider }?.metadata.displayName
      ?? provider.rawValue.capitalized
  }
}
