import AppKit
import SwiftUI

enum Theme {
  static let usageTrack = Color.primary.opacity(0.12)

  /// Status word for VoiceOver, so severity isn't conveyed by color alone.
  static func statusWord(_ usedPercent: Double) -> String {
    switch usedPercent {
    case ..<70: "normal"
    case ..<90: "warning"
    default: "critical"
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
