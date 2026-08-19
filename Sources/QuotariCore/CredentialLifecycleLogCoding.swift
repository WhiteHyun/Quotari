import Foundation

extension CredentialLifecycleLogStore {
  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  static func decodeLines(_ data: Data) -> [CredentialLifecycleEvent] {
    let decoder = makeDecoder()
    return data.split(separator: 0x0A).compactMap { line in
      try? decoder.decode(CredentialLifecycleEvent.self, from: Data(line))
    }
  }
}
