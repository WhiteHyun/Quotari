import AppKit

enum MenuBarIconStyle: String, CaseIterable, Sendable {
    case gauge
    case gaugeAndPercent
    
    var label: String {
        switch self {
        case .gauge: "Gauge only"
        case .gaugeAndPercent: "Gauge + percent"
        }
    }
}

/// Monochrome template menu-bar image; the system tints it to the menu bar.
enum IconRenderer {
    private static let height: CGFloat = 18
    private static let gaugeWidth: CGFloat = 24
    
    static func gaugeIcon(usedPercent: Double, loading: Bool, style: MenuBarIconStyle) -> NSImage {
        let showText = style == .gaugeAndPercent && !loading
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.black,
        ]
        // Fixed field for "100%" so the item never shifts width as digits grow.
        let fieldWidth: CGFloat = showText
            ? ceil(("100%" as NSString).size(withAttributes: textAttributes).width)
            : 0
        let gap: CGFloat = showText ? 4 : 0
        let totalWidth = gaugeWidth + gap + fieldWidth
        
        let image = NSImage(size: NSSize(width: totalWidth, height: height))
        image.lockFocus()
        drawGauge(
            usedPercent: usedPercent,
            loading: loading,
            in: CGRect(x: 0, y: 0, width: gaugeWidth, height: height)
        )
        if showText {
            let text = "\(Int(usedPercent.rounded()))%" as NSString
            let size = text.size(withAttributes: textAttributes)
            text.draw(
                at: CGPoint(x: gaugeWidth + gap, y: (height - size.height) / 2),
                withAttributes: textAttributes
            )
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
    
    private static func drawGauge(usedPercent: Double, loading: Bool, in bounds: CGRect) {
        let inset: CGFloat = 2
        let trackRect = CGRect(
            x: bounds.minX + inset,
            y: bounds.minY + 4,
            width: bounds.width - inset * 2,
            height: 10
        )
        let radius = trackRect.height / 2
        
        NSColor.black.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()
        
        guard !loading else {
            NSColor.black.withAlphaComponent(0.55).setFill()
            let bar = CGRect(
                x: trackRect.midX - 5,
                y: trackRect.midY - 1.5,
                width: 10,
                height: 3
            )
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
        
        let fraction = min(1, max(0, usedPercent / 100))
        if fraction > 0 {
            let fillWidth = max(3, (trackRect.width - 2) * fraction)
            let fillRect = CGRect(
                x: trackRect.minX + 1,
                y: trackRect.minY + 1,
                width: fillWidth,
                height: trackRect.height - 2
            )
            NSColor.black.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius - 1, yRadius: radius - 1).fill()
        }
    }
}
