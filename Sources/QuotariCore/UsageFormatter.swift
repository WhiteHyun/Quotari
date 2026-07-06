import Foundation

/// Pure presentation helpers — no state, no locale surprises.
public enum UsageFormatter {
    public static func percent(_ value: Double) -> String {
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// "in 2h 5m" / "in 3d 4h" / "now"
    public static func resetCountdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "in \(days)d \(hours % 24)h"
        }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }
}
