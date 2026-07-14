import Foundation

struct CodexAuthDocument: Decodable {
  let authMode: CodexAuthMode?
  let openAIAPIKey: String?
  let tokens: CodexTokenDocument?
  let lastRefresh: CodexTimestamp?
  let agentIdentity: CodexAgentIdentityDocument?
  let personalAccessToken: String?
  let bedrockAPIKey: CodexBedrockAPIKeyDocument?

  enum CodingKeys: String, CodingKey {
    case authMode = "auth_mode"
    case openAIAPIKey = "OPENAI_API_KEY"
    case tokens
    case lastRefresh = "last_refresh"
    case agentIdentity = "agent_identity"
    case personalAccessToken = "personal_access_token"
    case bedrockAPIKey = "bedrock_api_key"
  }
}

enum CodexAuthMode: String, Decodable {
  case apiKey = "apikey"
  case chatgpt
  case chatgptAuthTokens
  case headers
  case agentIdentity
  case personalAccessToken
  case bedrockAPIKey = "bedrockApiKey"
}

struct CodexTokenDocument: Decodable {
  let idToken: CodexIDToken
  let accessToken: String
  let refreshToken: String
  let accountID: String?

  enum CodingKeys: String, CodingKey {
    case idToken = "id_token"
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case accountID = "account_id"
  }
}

struct CodexTimestamp: Decodable {
  let value: String

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard Self.isValidRFC3339(value) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Codex refresh timestamp")
    }
    self.value = value
  }

  private static func isValidRFC3339(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 20,
          bytes[4] == 45,
          bytes[7] == 45,
          bytes[10] == 84 || bytes[10] == 116,
          bytes[13] == 58,
          bytes[16] == 58,
          let year = decimal(bytes[0 ..< 4]),
          let month = decimal(bytes[5 ..< 7]),
          let day = decimal(bytes[8 ..< 10]),
          let hour = decimal(bytes[11 ..< 13]),
          let minute = decimal(bytes[14 ..< 16]),
          let second = decimal(bytes[17 ..< 19]),
          (1 ... 12).contains(month),
          (1 ... daysInMonth(month, year: year)).contains(day),
          (0 ... 23).contains(hour),
          (0 ... 59).contains(minute),
          (0 ... 60).contains(second)
    else { return false }

    var position = 19
    if bytes[position] == 46 {
      position += 1
      let fractionalStart = position
      while position < bytes.count, (48 ... 57).contains(bytes[position]) {
        position += 1
      }
      guard position > fractionalStart else { return false }
    }

    if position + 1 == bytes.count, bytes[position] == 90 || bytes[position] == 122 {
      return true
    }
    guard position + 6 == bytes.count,
          bytes[position] == 43 || bytes[position] == 45,
          bytes[position + 3] == 58,
          let offsetHour = decimal(bytes[position + 1 ..< position + 3]),
          let offsetMinute = decimal(bytes[position + 4 ..< position + 6])
    else { return false }
    return (0 ... 23).contains(offsetHour) && (0 ... 59).contains(offsetMinute)
  }

  private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int? {
    guard !bytes.isEmpty, bytes.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
    return bytes.reduce(0) { $0 * 10 + Int($1 - 48) }
  }

  private static func daysInMonth(_ month: Int, year: Int) -> Int {
    switch month {
    case 2:
      let isLeapYear = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
      return isLeapYear ? 29 : 28
    case 4, 6, 9, 11:
      return 30
    default:
      return 31
    }
  }
}

struct CodexIDToken: Decodable {
  let value: String

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Codex ID token")
    }

    let encodedPayload = parts[1]
    let base64URLCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard encodedPayload.unicodeScalars.allSatisfy(base64URLCharacters.contains) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Codex ID token")
    }
    var payload = String(encodedPayload)
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 {
      payload.append("=")
    }
    guard let data = Data(base64Encoded: payload), data.base64URLEncodedString == encodedPayload else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Codex ID token")
    }
    var duplicateKeyValidator = CodexJSONDuplicateKeyValidator(data)
    guard duplicateKeyValidator.validate(),
          let projectedData = CodexJSONProjector.project(data, schema: .tokenClaims),
          (try? JSONDecoder().decode(CodexIDTokenClaims.self, from: projectedData)) != nil
    else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Codex ID token")
    }
    self.value = value
  }
}

private extension Data {
  var base64URLEncodedString: String {
    var encoded = base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
    while encoded.last == "=" {
      encoded.removeLast()
    }
    return encoded
  }
}

private struct CodexIDTokenClaims: Decodable {
  let email: String?
  let profile: CodexIDTokenProfileClaims?
  let auth: CodexIDTokenAuthClaims?

  enum CodingKeys: String, CodingKey {
    case email
    case profile = "https://api.openai.com/profile"
    case auth = "https://api.openai.com/auth"
  }
}

private struct CodexIDTokenProfileClaims: Decodable {
  let email: String?
}

private struct CodexIDTokenAuthClaims: Decodable {
  let chatgptPlanType: String?
  let chatgptUserID: String?
  let userID: String?
  let chatgptAccountID: String?
  let chatgptAccountIsFedramp: Bool

  enum CodingKeys: String, CodingKey {
    case chatgptPlanType = "chatgpt_plan_type"
    case chatgptUserID = "chatgpt_user_id"
    case userID = "user_id"
    case chatgptAccountID = "chatgpt_account_id"
    case chatgptAccountIsFedramp = "chatgpt_account_is_fedramp"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    chatgptPlanType = try container.decodeIfPresent(String.self, forKey: .chatgptPlanType)
    chatgptUserID = try container.decodeIfPresent(String.self, forKey: .chatgptUserID)
    userID = try container.decodeIfPresent(String.self, forKey: .userID)
    chatgptAccountID = try container.decodeIfPresent(String.self, forKey: .chatgptAccountID)
    chatgptAccountIsFedramp = if container.contains(.chatgptAccountIsFedramp) {
      try container.decode(Bool.self, forKey: .chatgptAccountIsFedramp)
    } else {
      false
    }
  }
}

enum CodexAgentIdentityDocument: Decodable {
  case jwt(String)
  case record(CodexAgentIdentityRecord)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let jwt = try? container.decode(String.self) {
      self = .jwt(jwt)
    } else {
      self = try .record(container.decode(CodexAgentIdentityRecord.self))
    }
  }
}

struct CodexAgentIdentityRecord: Decodable {
  let agentRuntimeID: String
  let agentPrivateKey: String
  let accountID: String
  let chatgptUserID: String
  let email: String?
  let planType: String
  let chatgptAccountIsFedramp: Bool
  let taskID: String?

  enum CodingKeys: String, CodingKey {
    case agentRuntimeID = "agent_runtime_id"
    case agentPrivateKey = "agent_private_key"
    case accountID = "account_id"
    case chatgptUserID = "chatgpt_user_id"
    case email
    case planType = "plan_type"
    case chatgptAccountIsFedramp = "chatgpt_account_is_fedramp"
    case taskID = "task_id"
  }
}

struct CodexBedrockAPIKeyDocument: Decodable {
  let apiKey: String
  let region: String

  enum CodingKeys: String, CodingKey {
    case apiKey = "api_key"
    case region
  }
}
