import Darwin
import Foundation

/// Prepares credential bytes in a same-directory, owner-only temporary file.
/// The live path is not touched until `commit`, whose POSIX rename is atomic.
/// This lets multi-store callers validate permissions before mutating a
/// keychain item and safely roll that item back if the final rename fails.
struct SecureCredentialFileWriter: Sendable {
  private let setOwnerOnlyPermissions: @Sendable (URL) throws -> Void

  init(setOwnerOnlyPermissions: @escaping @Sendable (URL) throws -> Void) {
    self.setOwnerOnlyPermissions = setOwnerOnlyPermissions
  }

  func prepare(_ data: Data, replacing destination: URL) throws -> URL {
    let template = destination.deletingLastPathComponent()
      .appendingPathComponent(Self.temporaryName(for: destination))
      .path
    var path = Array(template.utf8CString)
    let descriptor = mkstemp(&path)
    guard descriptor >= 0 else { throw Self.posixError() }
    let pathBytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard let temporaryPath = String(bytes: pathBytes, encoding: .utf8) else {
      Darwin.close(descriptor)
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let temporary = URL(fileURLWithPath: temporaryPath)
    var isOpen = true
    defer {
      if isOpen {
        Darwin.close(descriptor)
      }
    }

    do {
      guard fchmod(descriptor, 0o600) == 0 else { throw Self.posixError() }
      try Self.write(data, to: descriptor)
      guard fsync(descriptor) == 0 else { throw Self.posixError() }
      let closeResult = Darwin.close(descriptor)
      isOpen = false
      guard closeResult == 0 else { throw Self.posixError() }

      // Keep this injectable: tests must prove a chmod failure happens while
      // only a disposable temp file exists, never after live tokens changed.
      try setOwnerOnlyPermissions(temporary)
      try Self.requireOwnerOnlyPermissions(temporary)
      return temporary
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  func commit(_ temporary: URL, replacing destination: URL) throws {
    guard rename(temporary.path, destination.path) == 0 else {
      throw Self.posixError()
    }
  }

  func remove(_ destination: URL) throws {
    guard unlink(destination.path) == 0 || errno == ENOENT else {
      throw Self.posixError()
    }
  }

  func discard(_ temporary: URL?) {
    guard let temporary else { return }
    try? FileManager.default.removeItem(at: temporary)
  }

  private static func temporaryName(for destination: URL) -> String {
    let basename = destination.lastPathComponent
    return basename.hasPrefix(".")
      ? "\(basename).quotari.XXXXXX"
      : ".\(basename).quotari.XXXXXX"
  }

  private static func write(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var written = 0
      while written < rawBuffer.count {
        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: written),
          rawBuffer.count - written
        )
        if count < 0, errno == EINTR {
          continue
        }
        guard count > 0 else { throw Self.posixError() }
        written += count
      }
    }
  }

  private static func requireOwnerOnlyPermissions(_ url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber,
          permissions.intValue & 0o077 == 0
    else {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  private static func posixError() -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}
