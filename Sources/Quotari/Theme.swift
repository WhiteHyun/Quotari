import AppKit
import SwiftUI

enum Theme {
  static let brandAccent = Color(red: 0.96, green: 0.31, blue: 0.12)
  static let brandAccentSecondary = Color(red: 1, green: 0.57, blue: 0.22)
  static let settingsSidebarBackground = Color(nsColor: .windowBackgroundColor)
  static let settingsDetailBackground = Color(nsColor: .windowBackgroundColor)
  static let settingsCardBackground = Color(nsColor: .controlBackgroundColor)
  static let settingsSeparator = Color.primary.opacity(0.09)
  static let usageTrack = Color.primary.opacity(0.12)

  /// Status word for VoiceOver, so severity isn't conveyed by color alone.
  static func statusWord(_ usedPercent: Double) -> String {
    switch usedPercent {
    case ..<70: L10n.string("normal")
    case ..<90: L10n.string("warning")
    default: L10n.string("critical")
    }
  }

  /// The brand accent with saturation scaled by `intensity` (0...1), so low
  /// values read as a pale tint and peaks as the full brand color. Keeps a
  /// visible floor so tiny bars don't vanish.
  static func accent(_ accent: Color, intensity: Double) -> Color {
    var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
    NSColor(accent).usingColorSpace(.sRGB)?.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
    let t = CGFloat(min(1, max(0, intensity)))
    return Color(
      hue: Double(hue),
      saturation: Double(sat * (0.25 + 0.75 * t)),
      brightness: Double(bri)
    )
  }
}
