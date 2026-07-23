import AppKit
import Foundation
@testable import Quotari
import Testing

@MainActor
struct CustomMascotTests {
  @Test func importsOrderedPNGFramesAndPersistsSelection() throws {
    let context = try makeContext("ordered-frames")
    defer { context.remove() }
    let firstPNG = try pngData(width: 48, height: 36, color: .systemBlue)
    let secondPNG = try pngData(width: 48, height: 36, color: .systemOrange)
    let firstURL = context.directory.appendingPathComponent("owl-frame-0.png")
    let secondURL = context.directory.appendingPathComponent("owl-frame-1.png")
    try firstPNG.write(to: firstURL)
    try secondPNG.write(to: secondURL)

    let controller = context.makeController()
    try controller.importCustomMascot(from: [secondURL, firstURL])

    #expect(controller.preferences.mascot == .custom)
    #expect(controller.customMascotName == "owl")
    #expect(controller.customMascotFrameCount == 2)
    #expect(controller.mascotIcon(frame: 0).size == NSSize(width: 24, height: 18))
    let loaded = try CustomMascotStore.load(from: context.archiveURL)
    #expect(loaded.mascot.framePNGs == [firstPNG, secondPNG])
    #expect(loaded.decodedFrames.count == 2)

    let relaunched = context.makeController()
    #expect(relaunched.preferences.mascot == .custom)
    #expect(relaunched.customMascotName == "owl")
    #expect(relaunched.customMascotFrameCount == 2)

    try relaunched.removeCustomMascot()
    #expect(relaunched.preferences.mascot == .builtIn)
    #expect(!relaunched.hasCustomMascot)
    #expect(!FileManager.default.fileExists(atPath: context.archiveURL.path))
  }

  @Test func customMascotPreviewDoesNotFollowTheMenuBarSelection() throws {
    let context = try makeContext("management-preview")
    defer { context.remove() }
    let firstURL = context.directory.appendingPathComponent("preview-0.png")
    let secondURL = context.directory.appendingPathComponent("preview-1.png")
    try pngData(width: 48, height: 36, color: .systemBlue).write(to: firstURL)
    try pngData(width: 48, height: 36, color: .systemOrange).write(to: secondURL)
    let controller = context.makeController()
    try controller.importCustomMascot(from: [firstURL, secondURL])

    controller.setMascot(.builtIn)

    #expect(controller.mascotIcon(frame: 0).size == NSSize(width: 18, height: 18))
    let preview = try #require(controller.customMascotIcon(frame: 0))
    #expect(preview.size == NSSize(width: 24, height: 18))
  }

  @Test func replacingInactiveCustomMascotPreservesBuiltInSelection() throws {
    let context = try makeContext("replace-inactive")
    defer { context.remove() }
    let firstURL = context.directory.appendingPathComponent("first-0.png")
    let secondURL = context.directory.appendingPathComponent("first-1.png")
    try pngData(width: 36, height: 36, color: .systemBlue).write(to: firstURL)
    try pngData(width: 36, height: 36, color: .systemOrange).write(to: secondURL)
    let controller = context.makeController()
    try controller.importCustomMascot(from: [firstURL, secondURL])
    controller.setMascot(.builtIn)

    let replacementFirstURL = context.directory.appendingPathComponent("replacement-0.png")
    let replacementSecondURL = context.directory.appendingPathComponent("replacement-1.png")
    try pngData(width: 48, height: 36, color: .systemRed).write(to: replacementFirstURL)
    try pngData(width: 48, height: 36, color: .systemGreen).write(to: replacementSecondURL)

    try controller.importCustomMascot(from: [replacementFirstURL, replacementSecondURL])

    #expect(controller.preferences.mascot == .builtIn)
    #expect(controller.customMascotName == "replacement")
    #expect(controller.customMascotIcon(frame: 0)?.size == NSSize(width: 24, height: 18))
  }

  @Test func splitsAHorizontalSquareFrameSpriteSheet() throws {
    let context = try makeContext("sprite-sheet")
    defer { context.remove() }
    let sheetURL = context.directory.appendingPathComponent("tiny-robot.png")
    try spriteSheetPNG(frameSize: 36, colors: [.systemRed, .systemGreen, .systemBlue])
      .write(to: sheetURL)

    let imported = try CustomMascotStore.importedMascot(from: [sheetURL])
    let frames = IconRenderer.customMascotFrames(from: imported.decodedFrames)

    #expect(imported.mascot.name == "tiny-robot")
    #expect(imported.mascot.framePNGs.isEmpty)
    #expect(imported.mascot.spriteSheetPNG != nil)
    #expect(imported.decodedFrames.count == 3)
    #expect(frames.count == 3)
    #expect(frames.allSatisfy { $0.size == NSSize(width: 18, height: 18) })
  }

  @Test func splitsThirtyTwoFrameSpriteSheetUsingPerFrameDimensionLimits() throws {
    let context = try makeContext("wide-sprite-sheet")
    defer { context.remove() }
    let sheetURL = context.directory.appendingPathComponent("wide-runner.png")
    let colors = (0 ..< CustomMascotStore.maximumFrameCount).map { index in
      index.isMultiple(of: 2) ? NSColor.systemPurple : NSColor.systemTeal
    }
    try spriteSheetPNG(frameSize: 80, colors: colors).write(to: sheetURL)

    let imported = try CustomMascotStore.importedMascot(from: [sheetURL])

    #expect(imported.mascot.framePNGs.isEmpty)
    #expect(imported.mascot.spriteSheetPNG != nil)
    #expect(imported.decodedFrames.count == CustomMascotStore.maximumFrameCount)
    #expect(IconRenderer.customMascotFrames(from: imported.decodedFrames).count == 32)
  }

  @Test func rejectsTooManySelectedFramesBeforeReadingThem() throws {
    let context = try makeContext("too-many-frames")
    defer { context.remove() }
    let missingURLs = (0 ... CustomMascotStore.maximumFrameCount).map { index in
      context.directory.appendingPathComponent("missing-\(index).png")
    }

    #expect(throws: CustomMascotError.invalidFrameCount) {
      try CustomMascotStore.importedMascot(from: missingURLs)
    }
  }

  @Test func rejectsCombinedFrameBytesAtTheImportLimit() throws {
    let context = try makeContext("oversized-frames")
    defer { context.remove() }
    let firstURL = context.directory.appendingPathComponent("large-0.png")
    let secondURL = context.directory.appendingPathComponent("large-1.png")
    let oversizedHalf = Data(count: CustomMascotStore.maximumTotalBytes / 2 + 1)
    try oversizedHalf.write(to: firstURL)
    try oversizedHalf.write(to: secondURL)

    #expect(throws: CustomMascotError.fileTooLarge) {
      try CustomMascotStore.importedMascot(from: [firstURL, secondURL])
    }
  }

  @Test func rejectsFramesWithDifferentPixelSizes() throws {
    let context = try makeContext("mismatched-frames")
    defer { context.remove() }
    let firstURL = context.directory.appendingPathComponent("runner-0.png")
    let secondURL = context.directory.appendingPathComponent("runner-1.png")
    try pngData(width: 36, height: 36, color: .black).write(to: firstURL)
    try pngData(width: 48, height: 36, color: .black).write(to: secondURL)

    #expect(throws: CustomMascotError.mismatchedFrameSize) {
      try CustomMascotStore.importedMascot(from: [firstURL, secondURL])
    }
  }

  @Test func downsamplesAggregateFramesBeforeRetainingDecodedImages() throws {
    let context = try makeContext("aggregate-decoding")
    defer { context.remove() }
    let png = try pngData(width: 2048, height: 1024, color: .systemPurple)
    let frameURLs = try (0 ..< CustomMascotStore.maximumFrameCount).map { index in
      let url = context.directory.appendingPathComponent("runner-\(index).png")
      try png.write(to: url)
      return url
    }

    let imported = try CustomMascotStore.importedMascot(from: frameURLs)

    #expect(imported.decodedFrames.count == CustomMascotStore.maximumFrameCount)
    #expect(imported.decodedFrames.allSatisfy { frame in
      frame.width == 2048
        && frame.height == 1024
        && frame.image.width <= 100
        && frame.image.height <= 100
    })
    #expect(
      imported.decodedFrames.reduce(0) { pixels, frame in
        pixels + frame.image.width * frame.image.height
      } <= CustomMascotStore.maximumFrameCount * 100 * 100
    )
  }

  @Test func customMascotLayoutPreservesWideAndTallAspectRatios() {
    let wide = IconRenderer.customMascotLayout(pixelWidth: 600, pixelHeight: 100)
    #expect(wide.canvasSize == NSSize(width: 50, height: 18))
    #expect(abs(wide.drawingRect.width / wide.drawingRect.height - 6) < 0.001)
    #expect(wide.drawingRect.height < wide.canvasSize.height)

    let tall = IconRenderer.customMascotLayout(pixelWidth: 100, pixelHeight: 600)
    #expect(tall.canvasSize == NSSize(width: 8, height: 18))
    #expect(abs(tall.drawingRect.width / tall.drawingRect.height - 1 / 6) < 0.001)
    #expect(tall.drawingRect.width < tall.canvasSize.width)
  }

  @Test func recognizesOnlyCocoaFileImportCancellation() {
    let cancellation = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    let otherError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)

    #expect(isCancelledFileImport(cancellation))
    #expect(!isCancelledFileImport(otherError))
  }

  private struct TestContext {
    var defaults: UserDefaults
    var suiteName: String
    var directory: URL

    var archiveURL: URL {
      directory.appendingPathComponent("archive/custom-mascot.plist")
    }

    @MainActor func makeController() -> MenuBarPreferencesController {
      MenuBarPreferencesController(
        defaults: defaults,
        customMascotArchiveURL: archiveURL
      )
    }

    func remove() {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func makeContext(_ name: String) throws -> TestContext {
    let suiteName = "CustomMascotTests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return TestContext(defaults: defaults, suiteName: suiteName, directory: directory)
  }

  private func pngData(width: Int, height: Int, color: NSColor) throws -> Data {
    try imagePNG(width: width, height: height) { context in
      context.setFillColor(color.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  private func spriteSheetPNG(frameSize: Int, colors: [NSColor]) throws -> Data {
    try imagePNG(width: frameSize * colors.count, height: frameSize) { context in
      for (index, color) in colors.enumerated() {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: index * frameSize, y: 0, width: frameSize, height: frameSize))
      }
    }
  }

  private func imagePNG(
    width: Int,
    height: Int,
    draw: (CGContext) -> Void
  ) throws -> Data {
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    draw(context)
    let image = try #require(context.makeImage())
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
  }
}
