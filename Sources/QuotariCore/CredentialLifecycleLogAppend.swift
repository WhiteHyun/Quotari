import Foundation

extension CredentialLifecycleLogStore {
  static func appendCompleteLine(_ line: Data, to url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let endOffset = try handle.seekToEnd()
    if endOffset > 0 {
      try handle.seek(toOffset: endOffset - 1)
      let endsWithNewline = try handle.read(upToCount: 1)?.first == 0x0A
      try handle.seekToEnd()
      if !endsWithNewline {
        try handle.write(contentsOf: Data([0x0A]))
      }
    }
    try handle.write(contentsOf: line)
  }
}
