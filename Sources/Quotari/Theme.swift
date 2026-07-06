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
}
