import Foundation

indirect enum CodexJSONProjectionSchema {
  case value
  case object([String: CodexJSONProjectionSchema])

  static let authDocument = object(
    ["auth_mode", "OPENAI_API_KEY", "last_refresh", "personal_access_token"],
    nested: [
      "tokens": object(["id_token", "access_token", "refresh_token", "account_id"]),
      "agent_identity": object([
        "agent_runtime_id", "agent_private_key", "account_id", "chatgpt_user_id",
        "email", "plan_type", "chatgpt_account_is_fedramp", "task_id",
      ]),
      "bedrock_api_key": object(["api_key", "region"]),
    ]
  )

  static let tokenClaims = object(
    ["email", "exp"],
    nested: [
      "https://api.openai.com/profile": object(["email"]),
      "https://api.openai.com/auth": object([
        "chatgpt_plan_type", "chatgpt_user_id", "user_id", "chatgpt_account_id",
        "chatgpt_account_is_fedramp",
      ]),
    ]
  )

  private static func object(_ scalarKeys: [String], nested: [String: Self] = [:]) -> Self {
    var fields = Dictionary(uniqueKeysWithValues: scalarKeys.map { ($0, Self.value) })
    fields.merge(nested) { _, replacement in replacement }
    return .object(fields)
  }
}

struct CodexJSONProjector {
  private let bytes: [UInt8]
  private var position = 0

  private init(_ data: Data) {
    bytes = Array(data)
  }

  static func project(_ data: Data, schema: CodexJSONProjectionSchema) -> Data? {
    var projector = Self(data)
    projector.skipWhitespace()
    guard let result = projector.projectValue(schema) else { return nil }
    projector.skipWhitespace()
    guard projector.position == projector.bytes.count else { return nil }
    return Data(result)
  }

  static func topLevelFields(_ data: Data) -> [String: Data]? {
    var validator = CodexJSONDuplicateKeyValidator(data)
    guard validator.validate() else { return nil }
    var projector = Self(data)
    projector.skipWhitespace()
    guard let fields = projector.parseTopLevelObject() else { return nil }
    projector.skipWhitespace()
    return projector.position == projector.bytes.count ? fields : nil
  }

  static func replacingTopLevelFields(in data: Data, with replacements: [String: Data]) -> Data? {
    guard var fields = topLevelFields(data) else { return nil }
    fields.merge(replacements) { _, replacement in replacement }
    var result: [UInt8] = [123]
    for key in fields.keys.sorted() {
      guard let keyData = try? JSONEncoder().encode(key), let value = fields[key] else { return nil }
      if result.count > 1 {
        result.append(44)
      }
      result.append(contentsOf: Array(keyData) + [58] + value)
    }
    result.append(125)
    return Data(result)
  }

  private mutating func parseTopLevelObject() -> [String: Data]? {
    guard consume(123) else { return nil }
    var fields: [String: Data] = [:]
    skipWhitespace()
    guard !consume(125) else { return fields }
    while position < bytes.count {
      guard let key = parseString() else { return nil }
      skipWhitespace()
      guard consume(58) else { return nil }
      skipWhitespace()
      let valueStart = position
      guard skipValue() else { return nil }
      fields[key] = Data(bytes[valueStart ..< position])
      skipWhitespace()
      guard !consume(125) else { return fields }
      guard consume(44) else { return nil }
      skipWhitespace()
    }
    return nil
  }

  private mutating func projectValue(_ schema: CodexJSONProjectionSchema) -> [UInt8]? {
    skipWhitespace()
    switch schema {
    case .value:
      return copyValue()
    case let .object(fields):
      if position < bytes.count, bytes[position] == 123 {
        return projectObject(fields)
      } else {
        return copyValue()
      }
    }
  }

  // The state branches mirror JSON object grammar and projection choices.
  // swiftlint:disable:next cyclomatic_complexity
  private mutating func projectObject(_ fields: [String: CodexJSONProjectionSchema]) -> [UInt8]? {
    guard consume(123) else { return nil }
    var result: [UInt8] = [123]
    var wroteField = false
    skipWhitespace()
    guard !consume(125) else { return result + [125] }

    while position < bytes.count {
      let keyStart = position
      guard let key = parseString() else { return nil }
      let keyBytes = bytes[keyStart ..< position]
      skipWhitespace()
      guard consume(58) else { return nil }
      skipWhitespace()
      if let fieldSchema = fields[key] {
        guard let value = projectValue(fieldSchema) else { return nil }
        if wroteField {
          result.append(44)
        }
        result.append(contentsOf: Array(keyBytes) + [58] + value)
        wroteField = true
      } else if !skipValue() {
        return nil
      }

      skipWhitespace()
      guard !consume(125) else { return result + [125] }
      guard consume(44) else { return nil }
      skipWhitespace()
    }
    return nil
  }

  private mutating func copyValue() -> [UInt8]? {
    skipWhitespace()
    let start = position
    guard skipValue() else { return nil }
    return Array(bytes[start ..< position])
  }

  private mutating func skipValue() -> Bool {
    skipWhitespace()
    guard position < bytes.count else { return false }
    if bytes[position] == 34 {
      return parseString() != nil
    }
    if bytes[position] == 123 || bytes[position] == 91 {
      return skipContainer()
    }
    return skipPrimitive()
  }

  private mutating func skipContainer() -> Bool {
    var closingBytes: [UInt8] = [bytes[position] == 123 ? 125 : 93]
    position += 1
    while let closingByte = closingBytes.last {
      guard advanceContainer(&closingBytes, closingByte: closingByte) else { return false }
    }
    return true
  }

  private mutating func advanceContainer(_ closingBytes: inout [UInt8], closingByte: UInt8) -> Bool {
    guard position < bytes.count else { return false }
    switch bytes[position] {
    case 34:
      return parseString() != nil
    case 123:
      closingBytes.append(125)
      position += 1
    case 91:
      closingBytes.append(93)
      position += 1
    case closingByte:
      closingBytes.removeLast()
      position += 1
    case 93, 125:
      return false
    default:
      position += 1
    }
    return true
  }

  private mutating func skipPrimitive() -> Bool {
    let start = position
    while position < bytes.count, !Self.isDelimiter(bytes[position]) {
      position += 1
    }
    return position > start
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
}
