import AppKit
import Foundation
import ImageIO

enum MenuBarMascot: String, Codable, Equatable, Hashable, Sendable {
  case builtIn
  case custom
}

enum CustomMascotError: Error, Equatable, LocalizedError {
  case fileTooLarge
  case invalidPNG
  case invalidFrameCount
  case mismatchedFrameSize
  case unsupportedDimensions
  case storageFailure

  var errorDescription: String? {
    switch self {
    case .fileTooLarge:
      L10n.string("Custom mascot files must total 10 MB or less.")
    case .invalidPNG:
      L10n.string("Choose valid PNG images.")
    case .invalidFrameCount:
      L10n.string("A custom mascot needs between 2 and 32 frames.")
    case .mismatchedFrameSize:
      L10n.string("Every custom mascot frame must have the same pixel size.")
    case .unsupportedDimensions:
      L10n.string("Custom mascot frames use unsupported dimensions.")
    case .storageFailure:
      L10n.string("Quotari couldn’t save the custom mascot.")
    }
  }
}

struct StoredCustomMascot: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version = currentVersion
  var name: String
  var framePNGs: [Data]
}

@MainActor
enum CustomMascotStore {
  static let maximumFrameCount = 32
  static let maximumTotalBytes = 10_000_000

  static func defaultArchiveURL(fileManager: FileManager = .default) -> URL {
    let applicationSupport = (try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return applicationSupport
      .appendingPathComponent("Quotari/Mascots", isDirectory: true)
      .appendingPathComponent("custom-mascot.plist")
  }

  static func importedMascot(from urls: [URL]) throws -> StoredCustomMascot {
    let sortedURLs = urls.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    guard !sortedURLs.isEmpty, sortedURLs.count <= maximumFrameCount else {
      throw CustomMascotError.invalidFrameCount
    }

    let accessed = sortedURLs.map { url in
      (url, url.startAccessingSecurityScopedResource())
    }
    defer {
      for (url, didAccess) in accessed where didAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let framePNGs: [Data]
    if sortedURLs.count == 1 {
      let data = try readData(
        from: sortedURLs[0],
        remainingByteCount: maximumTotalBytes
      )
      framePNGs = try splitSpriteSheet(data)
    } else {
      var importedFrames: [Data] = []
      var totalBytes = 0
      for url in sortedURLs {
        let data = try readData(
          from: url,
          remainingByteCount: maximumTotalBytes - totalBytes
        )
        importedFrames.append(data)
        totalBytes += data.count
      }
      framePNGs = importedFrames
      _ = try CustomMascotFrameDecoder.decode(framePNGs)
    }

    guard framePNGs.count >= 2, framePNGs.count <= maximumFrameCount else {
      throw CustomMascotError.invalidFrameCount
    }
    guard framePNGs.reduce(0, { $0 + $1.count }) <= maximumTotalBytes else {
      throw CustomMascotError.fileTooLarge
    }

    return StoredCustomMascot(
      name: displayName(for: sortedURLs),
      framePNGs: framePNGs
    )
  }

  static func load(from url: URL) throws -> StoredCustomMascot {
    let data = try Data(contentsOf: url)
    let mascot = try PropertyListDecoder().decode(StoredCustomMascot.self, from: data)
    guard mascot.version == StoredCustomMascot.currentVersion else {
      throw CustomMascotError.storageFailure
    }
    _ = try CustomMascotFrameDecoder.decode(mascot.framePNGs)
    return mascot
  }

  static func save(_ mascot: StoredCustomMascot, to url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      try encoder.encode(mascot).write(to: url, options: .atomic)
    } catch {
      throw CustomMascotError.storageFailure
    }
  }

  static func remove(from url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw CustomMascotError.storageFailure
    }
  }

  private static func readData(
    from url: URL,
    remainingByteCount: Int
  ) throws -> Data {
    if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
       fileSize > remainingByteCount {
      throw CustomMascotError.fileTooLarge
    }

    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw CustomMascotError.invalidPNG
    }
    guard data.count <= remainingByteCount else { throw CustomMascotError.fileTooLarge }
    return data
  }

  private static func splitSpriteSheet(_ data: Data) throws -> [Data] {
    let decoded = try CustomMascotFrameDecoder.decodeSpriteSheet(data)
    guard decoded.width > decoded.height,
          decoded.width.isMultiple(of: decoded.height)
    else {
      throw CustomMascotError.invalidFrameCount
    }

    let frameCount = decoded.width / decoded.height
    guard frameCount >= 2, frameCount <= maximumFrameCount else {
      throw CustomMascotError.invalidFrameCount
    }

    var framePNGs: [Data] = []
    var totalBytes = 0
    for index in 0 ..< frameCount {
      let crop = CGRect(
        x: index * decoded.height,
        y: 0,
        width: decoded.height,
        height: decoded.height
      )
      guard let cropped = decoded.image.cropping(to: crop),
            let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
      else {
        throw CustomMascotError.invalidPNG
      }
      guard png.count <= maximumTotalBytes - totalBytes else {
        throw CustomMascotError.fileTooLarge
      }
      framePNGs.append(png)
      totalBytes += png.count
    }
    return framePNGs
  }

  private static func displayName(for urls: [URL]) -> String {
    let firstName = urls[0].deletingPathExtension().lastPathComponent
    guard urls.count > 1 else { return firstName }
    let trimmed = firstName.replacingOccurrences(
      of: "(?:[-_ ]?frame)?[-_ ]?\\d+$",
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    return trimmed.isEmpty ? L10n.string("Custom") : trimmed
  }
}

@MainActor
enum CustomMascotFrameDecoder {
  private static let maximumFrameWidth = 2048
  private static let maximumFrameHeight = 1024
  private static let maximumFrameAspectRatio = 6.0

  struct DecodedFrame {
    var image: CGImage
    var width: Int
    var height: Int
  }

  static func decode(_ framePNGs: [Data]) throws -> [DecodedFrame] {
    guard framePNGs.count >= 2, framePNGs.count <= CustomMascotStore.maximumFrameCount else {
      throw CustomMascotError.invalidFrameCount
    }
    guard framePNGs.reduce(0, { $0 + $1.count }) <= CustomMascotStore.maximumTotalBytes else {
      throw CustomMascotError.fileTooLarge
    }

    let frames = try framePNGs.map(decodeImage(_:))
    guard let first = frames.first else { throw CustomMascotError.invalidFrameCount }
    guard frames.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
      throw CustomMascotError.mismatchedFrameSize
    }
    return frames
  }

  static func decodeImage(_ data: Data) throws -> DecodedFrame {
    let frame = try decodePNG(
      data,
      maximumWidth: maximumFrameWidth,
      maximumHeight: maximumFrameHeight
    )
    guard Double(frame.width) / Double(frame.height) <= maximumFrameAspectRatio else {
      throw CustomMascotError.unsupportedDimensions
    }
    return frame
  }

  static func decodeSpriteSheet(_ data: Data) throws -> DecodedFrame {
    try decodePNG(
      data,
      maximumWidth: maximumFrameHeight * CustomMascotStore.maximumFrameCount,
      maximumHeight: maximumFrameHeight
    )
  }

  private static func decodePNG(
    _ data: Data,
    maximumWidth: Int,
    maximumHeight: Int
  ) throws -> DecodedFrame {
    let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    guard data.starts(with: pngSignature),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      throw CustomMascotError.invalidPNG
    }

    guard (1 ... maximumWidth).contains(width),
          (1 ... maximumHeight).contains(height)
    else {
      throw CustomMascotError.unsupportedDimensions
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw CustomMascotError.invalidPNG
    }
    return DecodedFrame(image: image, width: width, height: height)
  }
}
