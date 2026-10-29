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

  var menuBarQuotaText: String? {
    guard menuBarPreferences.preferences.showsRemainingPercent,
          let usedPercent = menuBarUsedPercent
    else { return nil }
    return MenuBarQuotaDisplay.text(
      usedPercent: usedPercent,
      presentation: menuBarPreferences.preferences.quotaPresentation
    )
  }

  func menuBarIcon(frame: Int) -> NSImage {
    menuBarPreferences.mascotIcon(frame: frame)
  }

  var menuBarMascotFrameCount: Int {
    menuBarPreferences.mascotFrameCount
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
    let preferences = menuBarPreferences.preferences
    let showsUsed = preferences.quotaPresentation == .used
    let quota = switch (preferences.usageSource, showsUsed) {
    case (.mostConstrained, false):
      L10n.string("lowest remaining quota")
    case (.mostConstrained, true):
      L10n.string("highest used quota")
    case let (.provider(provider), false):
      L10n.string("\(providerDisplayName(provider)) remaining quota")
    case let (.provider(provider), true):
      L10n.string("\(providerDisplayName(provider)) used quota")
    }
    let source = switch preferences.quotaWindow {
    case .automatic: quota
    case .session: L10n.string("\(quota), session window")
    case .weekly: L10n.string("\(quota), weekly window")
    }
    let value = showsUsed ? Int(usedPercent.rounded()) : remaining
    return L10n.string("Quotari, \(source) \(value) percent, \(Theme.statusWord(usedPercent))")
  }

  private func menuBarUsedPercent(for snapshot: UsageSnapshot) -> Double? {
    MenuBarQuotaDisplay.usedPercent(in: snapshot, window: menuBarPreferences.preferences.quotaWindow)
  }

  private func providerDisplayName(_ provider: UsageProvider) -> String {
    providers.first { $0.id == provider }?.metadata.displayName
      ?? provider.rawValue.capitalized
  }
}
