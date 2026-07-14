import Foundation

struct CodexJSONDuplicateKeyValidator {
  private enum State {
    case firstObjectKeyOrEnd
    case objectKey
    case objectColon
    case objectValue
    case objectCommaOrEnd
    case firstArrayValueOrEnd
    case arrayValue
    case arrayCommaOrEnd
  }

  private struct Frame {
    var state: State
    var keys = Set<String>()
  }

  private let bytes: [UInt8]
  private var position = 0
  private var frames: [Frame] = []

  init(_ data: Data) {
    bytes = Array(data)
  }

  mutating func validate() -> Bool {
    skipWhitespace()
    guard parseValue() else { return false }

    while let state = frames.last?.state {
      skipWhitespace()
      let frameIndex = frames.index(before: frames.endIndex)
      guard advance(state, at: frameIndex) else { return false }
    }

    skipWhitespace()
    return position == bytes.count
  }

  private mutating func advance(_ state: State, at frameIndex: Int) -> Bool {
    switch state {
    case .firstObjectKeyOrEnd:
      parseFirstObjectKey(at: frameIndex)
    case .objectKey:
      parseObjectKey(at: frameIndex)
    case .objectColon:
      parseObjectColon(at: frameIndex)
    case .objectValue:
      parseObjectValue(at: frameIndex)
    case .objectCommaOrEnd:
      parseObjectCommaOrEnd(at: frameIndex)
    case .firstArrayValueOrEnd:
      parseFirstArrayValue(at: frameIndex)
    case .arrayValue:
      parseArrayValue(at: frameIndex)
    case .arrayCommaOrEnd:
      parseArrayCommaOrEnd(at: frameIndex)
    }
  }

  private mutating func parseFirstObjectKey(at frameIndex: Int) -> Bool {
    if consume(125) {
      frames.removeLast()
      return true
    }
    return parseObjectKey(at: frameIndex)
  }

  private mutating func parseObjectKey(at frameIndex: Int) -> Bool {
    guard let key = parseString() else { return false }
    guard frames[frameIndex].keys.insert(key).inserted else { return false }
    frames[frameIndex].state = .objectColon
    return true
  }

  private mutating func parseObjectColon(at frameIndex: Int) -> Bool {
    guard consume(58) else { return false }
    frames[frameIndex].state = .objectValue
    return true
  }

  private mutating func parseObjectValue(at frameIndex: Int) -> Bool {
    frames[frameIndex].state = .objectCommaOrEnd
    return parseValue()
  }

  private mutating func parseObjectCommaOrEnd(at frameIndex: Int) -> Bool {
    if consume(125) {
      frames.removeLast()
      return true
    }
    guard consume(44) else { return false }
    frames[frameIndex].state = .objectKey
    return true
  }

  private mutating func parseFirstArrayValue(at frameIndex: Int) -> Bool {
    if consume(93) {
      frames.removeLast()
      return true
    }
    frames[frameIndex].state = .arrayCommaOrEnd
    return parseValue()
  }

  private mutating func parseArrayValue(at frameIndex: Int) -> Bool {
    frames[frameIndex].state = .arrayCommaOrEnd
    return parseValue()
  }

  private mutating func parseArrayCommaOrEnd(at frameIndex: Int) -> Bool {
    if consume(93) {
      frames.removeLast()
      return true
    }
    guard consume(44) else { return false }
    frames[frameIndex].state = .arrayValue
    return true
  }

  private mutating func parseValue() -> Bool {
    guard position < bytes.count else { return false }
    switch bytes[position] {
    case 123:
      position += 1
      frames.append(Frame(state: .firstObjectKeyOrEnd))
      return true
    case 91:
      position += 1
      frames.append(Frame(state: .firstArrayValueOrEnd))
      return true
    case 34:
      return parseString() != nil
    default:
      return parsePrimitive()
    }
  }

  private mutating func parseString() -> String? {
    guard consume(34) else { return nil }
    let start = position - 1
    while position < bytes.count {
      let byte = bytes[position]
      position += 1
      if byte == 34 {
        return try? JSONDecoder().decode(String.self, from: Data(bytes[start ..< position]))
      }
      if byte == 92 {
        guard position < bytes.count else { return nil }
        position += 1
      } else if byte < 32 {
        return nil
      }
    }
    return nil
  }

  private mutating func parsePrimitive() -> Bool {
    let start = position
    while position < bytes.count, !Self.isDelimiter(bytes[position]) {
      position += 1
    }
    let token = bytes[start ..< position]
    return token.elementsEqual([116, 114, 117, 101])
      || token.elementsEqual([102, 97, 108, 115, 101])
      || token.elementsEqual([110, 117, 108, 108])
      || Self.isJSONNumber(token)
  }

  private mutating func skipWhitespace() {
    while position < bytes.count, Self.isWhitespace(bytes[position]) {
      position += 1
    }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard position < bytes.count, bytes[position] == byte else { return false }
    position += 1
    return true
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }

  private static func isDelimiter(_ byte: UInt8) -> Bool {
    isWhitespace(byte) || byte == 44 || byte == 93 || byte == 125
  }

  private static func isJSONNumber(_ token: ArraySlice<UInt8>) -> Bool {
    let number = Array(token)
    guard !number.isEmpty else { return false }
    var index = 0
    if number[index] == 45 {
      index += 1
      guard index < number.count else { return false }
    }

    if number[index] == 48 {
      index += 1
    } else {
      guard (49 ... 57).contains(number[index]) else { return false }
      index += 1
      consumeDigits(in: number, from: &index)
    }

    if index < number.count, number[index] == 46 {
      index += 1
      let fractionStart = index
      consumeDigits(in: number, from: &index)
      guard index > fractionStart else { return false }
    }

    if index < number.count, number[index] == 69 || number[index] == 101 {
      index += 1
      if index < number.count, number[index] == 43 || number[index] == 45 {
        index += 1
      }
      let exponentStart = index
      consumeDigits(in: number, from: &index)
      guard index > exponentStart else { return false }
    }
    return index == number.count
  }

  private static func consumeDigits(in number: [UInt8], from index: inout Int) {
    while index < number.count, (48 ... 57).contains(number[index]) {
      index += 1
    }
  }
}
