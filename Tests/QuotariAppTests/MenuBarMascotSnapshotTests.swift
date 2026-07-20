import AppKit
@testable import Quotari
import Testing

@MainActor
struct MenuBarMascotSnapshotTests {
  @Test func mascotFramesAreDistinct() throws {
    let pngs = try (0 ..< IconRenderer.frameCount).map { frame in
      try pngData(for: IconRenderer.mascotIcon(frame: frame))
    }

    #expect(IconRenderer.frameCount == 8)
    #expect(Set(pngs).count == IconRenderer.frameCount)
  }

  @Test func renderMascotFrames() throws {
    let preview = NSImage(size: NSSize(width: 242, height: 40))
    preview.lockFocus()
    NSColor(calibratedRed: 0.08, green: 0.44, blue: 0.64, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: preview.size)).fill()
    for frame in 0 ..< IconRenderer.frameCount {
      let image = IconRenderer.mascotIcon(frame: frame)
      image.draw(in: NSRect(x: 10 + frame * 29, y: 11, width: 18, height: 18))
    }
    preview.unlockFocus()

    guard let data = preview.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
      Issue.record("Could not render menu-bar mascot preview")
      return
    }
    let output = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Snapshots/menubar-mascot.png")
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: output)
    #expect(png.count > 100)
    #expect(IconRenderer.frameCount == 8)
  }

  @Test func animationRateTracksQuotaPressure() {
    #expect(IconRenderer.animationInterval(usedPercent: 69) == 0.22)
    #expect(IconRenderer.animationInterval(usedPercent: 70) == 0.15)
    #expect(IconRenderer.animationInterval(usedPercent: 89) == 0.15)
    #expect(IconRenderer.animationInterval(usedPercent: 90) == 0.11)
  }

  private func pngData(for image: NSImage) throws -> Data {
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}
