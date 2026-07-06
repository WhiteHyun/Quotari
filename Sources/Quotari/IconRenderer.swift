import AppKit

/// Draws the menu-bar gauge as an `NSImage` with Core Graphics. This is the one
/// piece rendered by hand — everything inside the popover is SwiftUI. Severity
/// colors come from `Theme` so the bar and the cards always agree.
enum IconRenderer {
    private static let size = NSSize(width: 26, height: 18)

    static func gaugeIcon(usedPercent: Double, loading: Bool) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let inset: CGFloat = 2
        let trackRect = CGRect(x: inset, y: 4, width: size.width - inset * 2, height: 10)
        let radius = trackRect.height / 2

        // Track outline.
        let track = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
        NSColor.tertiaryLabelColor.setStroke()
        track.lineWidth = 1
        track.stroke()

        guard !loading else {
            // Pulse dot while we have no data yet.
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: trackRect.midX - 2, y: trackRect.midY - 2, width: 4, height: 4)).fill()
            return image
        }

        // Fill proportional to usage, colored by severity.
        let fraction = min(1, max(0, usedPercent / 100))
        let fillWidth = (trackRect.width - 2) * fraction
        if fillWidth > 0.5 {
            let fillRect = CGRect(
                x: trackRect.minX + 1,
                y: trackRect.minY + 1,
                width: fillWidth,
                height: trackRect.height - 2)
            Theme.severityNSColor(usedPercent).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius - 1, yRadius: radius - 1).fill()
        }
        return image
    }
}
