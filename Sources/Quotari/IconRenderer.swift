import AppKit
import Foundation

/// Renders the Quotari flame mascot as a compact, animated menu-bar item.
/// Its animation speeds up as the most-constrained quota gets closer to its limit.
enum IconRenderer {
  static let frameCount = 4
  private static let iconSize = NSSize(width: 18, height: 18)
  private static let frameBounds = [
    NSRect(x: 126.89, y: 200.39, width: 368.22, height: 368.22),
    NSRect(x: 588.73, y: 151.73, width: 411.54, height: 411.54),
    NSRect(x: 1_125.64, y: 165.64, width: 396.72, height: 396.72),
    NSRect(x: 1_629, y: 123.26, width: 435.48, height: 435.48),
  ]
  private static let frames = makeFrames()

  static func mascotIcon(frame: Int) -> NSImage {
    guard !frames.isEmpty else { return NSImage(size: iconSize) }
    return frames[frame % frames.count]
  }

  static func animationInterval(usedPercent: Double) -> TimeInterval {
    switch usedPercent {
    case ..<70: 0.5
    case ..<90: 0.25
    default: 0.12
    }
  }

  private static func makeFrames() -> [NSImage] {
    guard let url = Bundle.module.url(forResource: "flame-mascot-sprite", withExtension: "png"),
          let data = try? Data(contentsOf: url),
          let sprite = NSBitmapImageRep(data: data),
          sprite.hasAlpha
    else { return [] }

    return frameBounds.map { bounds in
      let frame = NSImage(size: iconSize)
      frame.lockFocus()
      sprite.draw(
        in: NSRect(origin: .zero, size: iconSize),
        from: bounds,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
      )
      frame.unlockFocus()
      frame.isTemplate = false
      return frame
    }
  }
}
