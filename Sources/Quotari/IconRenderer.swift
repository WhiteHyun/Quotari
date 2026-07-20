import AppKit
import Foundation

/// Renders the Quotari flame mascot as a compact, animated menu-bar item.
/// Its animation speeds up as the most-constrained quota gets closer to its limit.
enum IconRenderer {
  private static let resourceBundle: Bundle = {
    if let url = Bundle.main.url(forResource: "Quotari_Quotari", withExtension: "bundle"),
       let packaged = Bundle(url: url) {
      return packaged
    }
    return .module
  }()

  private static let iconSize = NSSize(width: 18, height: 18)
  private static let frameSize: CGFloat = 256
  private static let frameBounds = (0 ..< 8).map { index in
    NSRect(x: CGFloat(index) * frameSize, y: 0, width: frameSize, height: frameSize)
  }

  private static let frames = makeFrames()
  static var frameCount: Int {
    frames.count
  }

  /// Used by the release packaging smoke check to reject SwiftPM's absolute
  /// build-directory fallback and prove the copied app owns the decoded sprite.
  static var packagedResourcesAreReady: Bool {
    guard let resourceURL = Bundle.main.resourceURL else { return false }
    return frameCount > 1
      && resourceBundle.bundleURL.deletingLastPathComponent().standardizedFileURL
      == resourceURL.standardizedFileURL
  }

  static func mascotIcon(frame: Int) -> NSImage {
    guard !frames.isEmpty else { return NSImage(size: iconSize) }
    return frames[frame % frames.count]
  }

  static func animationInterval(usedPercent: Double) -> TimeInterval {
    switch usedPercent {
    case ..<70: 0.22
    case ..<90: 0.15
    default: 0.11
    }
  }

  private static func makeFrames() -> [NSImage] {
    guard let url = resourceBundle.url(forResource: "flame-mascot-sprite", withExtension: "png"),
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
