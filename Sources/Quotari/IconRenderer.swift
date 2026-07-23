import AppKit
import Foundation

/// Renders the Quotari flame mascot as a compact, animated menu-bar item.
/// Its animation speeds up as the most-constrained quota gets closer to its limit.
enum IconRenderer {
  static let resourceBundle: Bundle = {
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

  private static let artworkFrames = makeArtworkFrames()
  private static let frames = makeFrames()
  static var frameCount: Int {
    frames.count
  }

  /// Used by the release packaging smoke check to reject SwiftPM's absolute
  /// build-directory fallback and prove the copied app owns the decoded sprite.
  static var packagedResourcesAreReady: Bool {
    guard let resourceURL = Bundle.main.resourceURL else { return false }
    return frameCount > 1
      && ProviderIconAsset.resourcesAreReady
      && L10n.packagedResourcesAreReady
      && resourceBundle.bundleURL.deletingLastPathComponent().standardizedFileURL
      == resourceURL.standardizedFileURL
  }

  static func mascotIcon(frame: Int) -> NSImage {
    guard !frames.isEmpty else { return NSImage(size: iconSize) }
    return frames[frame % frames.count]
  }

  @MainActor
  static func customMascotFrames(from framePNGs: [Data]) throws -> [NSImage] {
    let decodedFrames = try CustomMascotFrameDecoder.decode(framePNGs)
    return customMascotFrames(from: decodedFrames)
  }

  @MainActor
  static func customMascotFrames(
    from decodedFrames: [CustomMascotFrameDecoder.DecodedFrame]
  ) -> [NSImage] {
    decodedFrames.map { decoded in
      makeMenuBarFrame(
        image: decoded.image,
        pixelWidth: decoded.width,
        pixelHeight: decoded.height
      )
    }
  }

  /// A high-resolution mascot frame for Settings and other large surfaces.
  /// Menu-bar callers should keep using `mascotIcon(frame:)`, which is tuned
  /// for the 18-point status item instead.
  static func mascotArtwork(frame: Int) -> NSImage {
    guard !artworkFrames.isEmpty else { return NSImage(size: NSSize(width: frameSize, height: frameSize)) }
    return artworkFrames[frame % artworkFrames.count]
  }

  static func animationInterval(usedPercent: Double) -> TimeInterval {
    switch usedPercent {
    case ..<70: 0.22
    case ..<90: 0.15
    default: 0.11
    }
  }

  private static func makeFrames() -> [NSImage] {
    artworkFrames.map { artwork in
      let frame = NSImage(size: iconSize)
      frame.lockFocus()
      artwork.draw(
        in: NSRect(origin: .zero, size: iconSize),
        from: NSRect(origin: .zero, size: artwork.size),
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

  private static func makeMenuBarFrame(
    image: CGImage,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> NSImage {
    let layout = customMascotLayout(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    let source = NSImage(
      cgImage: image,
      size: NSSize(width: pixelWidth, height: pixelHeight)
    )
    let frame = NSImage(size: layout.canvasSize)
    frame.lockFocus()
    source.draw(
      in: layout.drawingRect,
      from: NSRect(origin: .zero, size: source.size),
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: false,
      hints: [.interpolation: NSImageInterpolation.high]
    )
    frame.unlockFocus()
    frame.isTemplate = false
    return frame
  }

  static func customMascotLayout(
    pixelWidth: Int,
    pixelHeight: Int
  ) -> (canvasSize: NSSize, drawingRect: NSRect) {
    let aspectRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
    let canvasSize = NSSize(
      width: min(50, max(8, iconSize.height * aspectRatio)),
      height: iconSize.height
    )
    let scale = min(
      canvasSize.width / CGFloat(pixelWidth),
      canvasSize.height / CGFloat(pixelHeight)
    )
    let drawingSize = NSSize(
      width: CGFloat(pixelWidth) * scale,
      height: CGFloat(pixelHeight) * scale
    )
    return (
      canvasSize,
      NSRect(
        x: (canvasSize.width - drawingSize.width) / 2,
        y: (canvasSize.height - drawingSize.height) / 2,
        width: drawingSize.width,
        height: drawingSize.height
      )
    )
  }

  private static func makeArtworkFrames() -> [NSImage] {
    guard let url = resourceBundle.url(forResource: "flame-mascot-sprite", withExtension: "png"),
          let data = try? Data(contentsOf: url),
          let sprite = NSBitmapImageRep(data: data),
          let source = sprite.cgImage,
          sprite.hasAlpha,
          sprite.pixelsWide.isMultiple(of: frameBounds.count)
    else { return [] }

    let pixelFrameWidth = sprite.pixelsWide / frameBounds.count
    guard pixelFrameWidth == sprite.pixelsHigh else { return [] }

    return frameBounds.indices.compactMap { index in
      let crop = CGRect(
        x: CGFloat(index * pixelFrameWidth),
        y: 0,
        width: CGFloat(pixelFrameWidth),
        height: CGFloat(sprite.pixelsHigh)
      )
      guard let cropped = source.cropping(to: crop) else { return nil }

      let representation = NSBitmapImageRep(cgImage: cropped)
      representation.size = NSSize(width: frameSize, height: frameSize)
      let frame = NSImage(size: representation.size)
      frame.addRepresentation(representation)
      frame.isTemplate = false
      return frame
    }
  }
}
