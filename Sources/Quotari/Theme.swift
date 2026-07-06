import AppKit
import SwiftUI

/// Shared design tokens so the gauge (AppKit/CG) and the cards (SwiftUI) speak
/// the same visual language and the severity thresholds live in exactly one place.
enum Theme {
    static let cardCorner: CGFloat = 12

    /// Usage severity color: calm green → caution yellow → warning red.
    static func severity(_ usedPercent: Double) -> Color {
        switch usedPercent {
        case ..<70: .green
        case ..<90: .yellow
        default: .red
        }
    }

    /// AppKit twin of `severity(_:)` for the Core Graphics menu-bar gauge.
    static func severityNSColor(_ usedPercent: Double) -> NSColor {
        switch usedPercent {
        case ..<70: .systemGreen
        case ..<90: .systemYellow
        default: .systemRed
        }
    }
}
