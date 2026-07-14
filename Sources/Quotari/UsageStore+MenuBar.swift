import AppKit

extension UsageStore {
  var highestUsedPercent: Double {
    snapshots.values.map(\.highestUsedPercent).max() ?? 0
  }

  func menuBarIcon(frame: Int) -> NSImage {
    IconRenderer.mascotIcon(frame: frame)
  }

  var menuBarAnimationInterval: TimeInterval {
    IconRenderer.animationInterval(usedPercent: highestUsedPercent)
  }

  var menuBarAccessibilityLabel: String {
    guard !snapshots.isEmpty else { return "Quotari, loading usage" }
    let remaining = Int((100 - highestUsedPercent).rounded())
    return "Quotari, lowest remaining quota \(remaining) percent, \(Theme.statusWord(highestUsedPercent))"
  }
}
