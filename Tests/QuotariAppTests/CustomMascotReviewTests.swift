import AppKit
import Foundation
@testable import Quotari
import Testing

@MainActor
struct CustomMascotReviewTests {
  @Test func rejectsFramesTallerThanTheAspectRatioLimit() throws {
    let png = try pngData(width: 100, height: 700, color: .systemIndigo)

    #expect(throws: CustomMascotError.unsupportedDimensions) {
      try CustomMascotFrameDecoder.decodeImage(png)
    }
  }

  @Test func reportsRemovalFailuresSeparatelyFromStorageFailures() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CustomMascotReviewTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("custom-mascot.plist")
    try Data("mascot".utf8).write(to: archiveURL)

    #expect(throws: CustomMascotError.removalFailure) {
      try CustomMascotStore.remove(
        from: archiveURL,
        fileManager: FailingRemovalFileManager()
      )
    }
  }

  private func pngData(width: Int, height: Int, color: NSColor) throws -> Data {
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
  }
}

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at URL: URL) throws {
    throw CocoaError(.fileWriteNoPermission)
  }
}
