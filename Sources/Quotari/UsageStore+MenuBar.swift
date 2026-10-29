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
    guard menuBarPreferences.preferences.valueMode == .remainingQuota,
          let usedPercent = menuBarUsedPercent
    else { return nil }
    return MenuBarQuotaDisplay.text(
      usedPercent: usedPercent,
      presentation: menuBarPreferences.preferences.quotaPresentation
    )
  }

  /// The value beside the mascot for the chosen mode, or nil for the mascot alone.
  var menuBarValueText: String? {
    switch menuBarPreferences.preferences.valueMode {
    case .hidden:
      nil
    case .remainingQuota:
      menuBarQuotaText
    case .todayCost:
      menuBarTodayCost.map { MenuBarCostDisplay.text($0) }
    }
  }

  /// Nil until a cost source is chosen, and while that provider is disabled.
  var menuBarTodayCost: TodayCost? {
    guard let provider = menuBarPreferences.preferences.costSource,
          isProviderEnabled(provider)
    else { return nil }
    return MenuBarCostDisplay.current(
      MenuBarCostDisplay.resolve(usageInsightsState(for: provider), now: Date()),
      remembered: lastTodayCosts[provider]
    )
  }

  func menuBarIcon(frame: Int) -> NSImage {
    let icon = menuBarPreferences.mascotIcon(frame: frame)
    return hasActiveProviderOutage ? IconRenderer.withIncidentBadge(icon) : icon
  }

  var menuBarMascotFrameCount: Int {
    menuBarPreferences.mascotFrameCount
  }

  var menuBarAnimationInterval: TimeInterval {
    IconRenderer.animationInterval(usedPercent: menuBarUsedPercent ?? 0)
  }

  var menuBarAccessibilityLabel: String {
    let label = menuBarValueAccessibilityLabel
    return hasActiveProviderOutage ? L10n.string("\(label), service incident") : label
  }

  private var menuBarValueAccessibilityLabel: String {
    guard !enabledProviderDescriptors.isEmpty else {
      return L10n.string("Quotari, no providers enabled")
    }
    if menuBarPreferences.preferences.valueMode == .todayCost {
      return MenuBarCostDisplay.accessibilityLabel(
        providerName: menuBarPreferences.preferences.costSource.map(providerDisplayName),
        cost: menuBarTodayCost,
        now: Date()
      )
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
