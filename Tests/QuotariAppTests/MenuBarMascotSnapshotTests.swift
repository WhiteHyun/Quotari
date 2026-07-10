import AppKit
@testable import Quotari
import Testing

@MainActor
struct MenuBarMascotSnapshotTests {
  @Test func renderMascotFrames() throws {
    let preview = NSImage(size: NSSize(width: 176, height: 40))
    preview.lockFocus()
    NSColor(calibratedRed: 0.08, green: 0.44, blue: 0.64, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: preview.size)).fill()
    for frame in 0 ..< 4 {
      let image = IconRenderer.mascotIcon(frame: frame)
      image.draw(in: NSRect(x: 20 + frame * 40, y: 11, width: 18, height: 18))
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
  }

  @Test func animationRateTracksQuotaPressure() {
    #expect(IconRenderer.animationInterval(usedPercent: 69) == 0.5)
    #expect(IconRenderer.animationInterval(usedPercent: 70) == 0.25)
    #expect(IconRenderer.animationInterval(usedPercent: 89) == 0.25)
    #expect(IconRenderer.animationInterval(usedPercent: 90) == 0.12)
  }
}
