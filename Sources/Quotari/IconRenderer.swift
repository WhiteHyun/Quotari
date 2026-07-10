import AppKit

enum MenuBarIconStyle: String, CaseIterable {
  case gauge
  case gaugeAndPercent

  var label: String {
    switch self {
    case .gauge: "Quota meter"
    case .gaugeAndPercent: "Quota meter + remaining"
    }
  }
}

/// Monochrome template menu-bar image; the system tints it to the menu bar.
enum IconRenderer {
  private static let height: CGFloat = 18
  private static let meterWidth: CGFloat = 18

  /// Shows the least remaining quota, which is the limit most likely to need
  /// attention. The optional percentage uses the same remaining value.
  static func meterIcon(remainingPercent: Double, loading: Bool, style: MenuBarIconStyle) -> NSImage {
    let showText = style == .gaugeAndPercent && !loading
    let textFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let textAttributes: [NSAttributedString.Key: Any] = [
      .font: textFont,
      .foregroundColor: NSColor.black,
    ]
    // Fixed field for "100%" so the item never shifts width as quota changes.
    let fieldWidth: CGFloat = showText
      ? ceil(("100%" as NSString).size(withAttributes: textAttributes).width)
      : 0
    let gap: CGFloat = showText ? 4 : 0
    let totalWidth = meterWidth + gap + fieldWidth

    let image = NSImage(size: NSSize(width: totalWidth, height: height))
    image.lockFocus()
    drawMeter(
      remainingPercent: remainingPercent,
      loading: loading,
      in: CGRect(x: 0, y: 0, width: meterWidth, height: height)
    )
    if showText {
      let text = "\(Int(remainingPercent.rounded()))%" as NSString
      let size = text.size(withAttributes: textAttributes)
      text.draw(
        at: CGPoint(x: meterWidth + gap, y: (height - size.height) / 2),
        withAttributes: textAttributes
      )
    }
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  private static func drawMeter(remainingPercent: Double, loading: Bool, in bounds: CGRect) {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let radius: CGFloat = 6
    let track = NSBezierPath()
    track.lineWidth = 2
    track.lineCapStyle = .round
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
    NSColor.black.withAlphaComponent(0.26).setStroke()
    track.stroke()

    let fraction = loading ? 0.22 : min(1, max(0, remainingPercent / 100))
    guard fraction > 0 else { return }

    let progress = NSBezierPath()
    progress.lineWidth = 2.4
    progress.lineCapStyle = .round
    progress.appendArc(
      withCenter: center,
      radius: radius,
      startAngle: 90,
      endAngle: 90 - 360 * fraction,
      clockwise: true
    )
    NSColor.black.withAlphaComponent(0.92).setStroke()
    progress.stroke()
  }
}
