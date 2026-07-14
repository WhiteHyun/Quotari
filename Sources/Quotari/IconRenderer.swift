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

  private static let stepsPerTransition = 3
  private static let iconSize = NSSize(width: 18, height: 18)
  private static let bitmapScale = 2
  private static let frameBounds = [
    NSRect(x: 126.89, y: 200.39, width: 368.22, height: 368.22),
    NSRect(x: 588.73, y: 151.73, width: 411.54, height: 411.54),
    NSRect(x: 1125.64, y: 165.64, width: 396.72, height: 396.72),
    NSRect(x: 1629, y: 123.26, width: 435.48, height: 435.48),
  ]
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
    case ..<70: 0.16
    case ..<90: 0.1
    default: 0.075
    }
  }

  private static func makeFrames() -> [NSImage] {
    guard let url = resourceBundle.url(forResource: "flame-mascot-sprite", withExtension: "png"),
          let data = try? Data(contentsOf: url),
          let sprite = NSBitmapImageRep(data: data),
          sprite.hasAlpha
    else { return [] }

    let keyframes = frameBounds.map { bounds in
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
    return makeTransitionFrames(from: keyframes)
  }

  private static func makeTransitionFrames(from keyframes: [NSImage]) -> [NSImage] {
    guard keyframes.count > 1 else { return keyframes }
    return keyframes.indices.flatMap { index in
      let current = keyframes[index]
      let next = keyframes[(index + 1) % keyframes.count]
      return (0 ..< stepsPerTransition).map { step in
        blend(current, with: next, progress: CGFloat(step) / CGFloat(stepsPerTransition))
      }
    }
  }

  private static func blend(_ current: NSImage, with next: NSImage, progress: CGFloat) -> NSImage {
    guard progress > 0 else { return current }
    guard let currentBitmap = bitmap(from: current),
          let nextBitmap = bitmap(from: next),
          let blended = emptyBitmap()
    else {
      assertionFailure("Could not create bitmap representations for mascot frame blending")
      return current
    }

    for x in 0 ..< blended.pixelsWide {
      for y in 0 ..< blended.pixelsHigh {
        var currentPixel = [Int](repeating: 0, count: 4)
        var nextPixel = [Int](repeating: 0, count: 4)
        currentBitmap.getPixel(&currentPixel, atX: x, y: y)
        nextBitmap.getPixel(&nextPixel, atX: x, y: y)
        var pixel = interpolate(currentPixel, nextPixel, progress: progress)
        blended.setPixel(&pixel, atX: x, y: y)
      }
    }

    let frame = NSImage(size: iconSize)
    blended.size = iconSize
    frame.addRepresentation(blended)
    frame.isTemplate = false
    return frame
  }

  private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
    guard let bitmap = emptyBitmap() else {
      assertionFailure("Could not allocate a mascot frame bitmap")
      return nil
    }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      assertionFailure("Could not create a drawing context for a mascot frame bitmap")
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(origin: .zero, size: iconSize))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  private static func emptyBitmap() -> NSBitmapImageRep? {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(iconSize.width) * bitmapScale,
      pixelsHigh: Int(iconSize.height) * bitmapScale,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .calibratedRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return nil }
    bitmap.size = iconSize
    return bitmap
  }

  private static func interpolate(_ from: [Int], _ to: [Int], progress: CGFloat) -> [Int] {
    let fromWeight = 1 - progress
    return (0 ..< 4).map { index in
      let value = CGFloat(from[index]) * fromWeight + CGFloat(to[index]) * progress
      return Int(value.rounded())
    }
  }
}
