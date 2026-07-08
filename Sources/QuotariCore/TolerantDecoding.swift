import Foundation

enum LenientDateParser {
  static func parse(_ value: Any?) -> Date? {
    switch value {
    case let date as Date:
      date
    case let double as Double:
      date(fromEpoch: double)
    case let int as Int:
      date(fromEpoch: Double(int))
    case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
      date(fromEpoch: number.doubleValue)
    case let string as String:
      parse(string)
    default:
      nil
    }
  }

  static func parse(_ string: String) -> Date? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let epoch = Double(trimmed) {
      return date(fromEpoch: epoch)
    }

    for candidate in candidates(for: trimmed) {
      if let date = iso8601Date(from: candidate) {
        return date
      }
      if let date = formattedDate(from: candidate) {
        return date
      }
    }
    return nil
  }

  private static func date(fromEpoch epoch: Double) -> Date? {
    guard epoch.isFinite else { return nil }
    let magnitude = abs(epoch)
    let seconds: Double = if magnitude >= 1_000_000_000_000_000_000 {
      epoch / 1_000_000_000
    } else if magnitude >= 1_000_000_000_000_000 {
      epoch / 1_000_000
    } else if magnitude >= 100_000_000_000 {
      epoch / 1000
    } else {
      epoch
    }
    return Date(timeIntervalSince1970: seconds)
  }

  private static func candidates(for string: String) -> [String] {
    var candidates = [string]
    func appendCandidate(_ candidate: String) {
      if !candidates.contains(candidate) {
        candidates.append(candidate)
      }
    }

    if string.hasSuffix("z") {
      appendCandidate(String(string.dropLast()) + "Z")
    }
    if let firstSpace = string.firstIndex(of: " "),
       string[..<firstSpace].contains("-"),
       !string[..<firstSpace].contains("T")
    {
      var replaced = string
      replaced.replaceSubrange(firstSpace ... firstSpace, with: "T")
      appendCandidate(replaced)
    }
    return candidates
  }

  private static func iso8601Date(from string: String) -> Date? {
    let optionSets: [ISO8601DateFormatter.Options] = [
      [.withInternetDateTime, .withFractionalSeconds],
      [.withInternetDateTime],
      [.withFullDate, .withDashSeparatorInDate],
    ]
    for options in optionSets {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if let date = formatter.date(from: string) {
        return date
      }
    }
    return nil
  }

  private static func formattedDate(from string: String) -> Date? {
    let formats = [
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
      "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
      "yyyy-MM-dd'T'HH:mm:ssXXXXX",
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
      "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
      "yyyy-MM-dd'T'HH:mm:ssZ",
      "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX",
      "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
      "yyyy-MM-dd HH:mm:ssXXXXX",
      "yyyy-MM-dd HH:mm:ss.SSSSSSZ",
      "yyyy-MM-dd HH:mm:ss.SSSZ",
      "yyyy-MM-dd HH:mm:ssZ",
      "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
      "yyyy-MM-dd'T'HH:mm:ss.SSS",
      "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd HH:mm:ss.SSSSSS",
      "yyyy-MM-dd HH:mm:ss.SSS",
      "yyyy-MM-dd HH:mm:ss",
      "yyyy-MM-dd",
    ]
    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: string) {
        return date
      }
    }
    return nil
  }
}

/// A `Double` decoded leniently: accepts a number or a numeric string
/// ("73", "73.5"). Anything else decodes as `nil` instead of throwing, so one
/// odd field can't sink a whole payload.
public struct LenientDouble: Decodable, Equatable, Sendable {
  public var value: Double?

  public init(_ value: Double?) {
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let double = try? container.decode(Double.self) {
      value = double
    } else if let string = try? container.decode(String.self) {
      value = Double(string)
    } else {
      value = nil
    }
  }
}

/// A `Date` decoded leniently: accepts Unix epoch seconds (number) or an
/// ISO 8601 string. Unknown formats decode as `nil`.
public struct LenientDate: Decodable, Equatable, Sendable {
  public var value: Date?

  public init(_ value: Date?) {
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let seconds = try? container.decode(Double.self) {
      value = LenientDateParser.parse(seconds)
    } else if let string = try? container.decode(String.self) {
      value = LenientDateParser.parse(string)
    } else {
      value = nil
    }
  }
}

/// An array whose elements decode independently — elements that fail are
/// dropped instead of failing the whole array, so one malformed entry in a
/// provider response can't hide the rest.
public struct LossyArray<Element: Decodable>: Decodable {
  public var elements: [Element]

  public init(_ elements: [Element]) {
    self.elements = elements
  }

  public init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var decoded: [Element] = []
    while !container.isAtEnd {
      if let element = try? container.decode(Element.self) {
        decoded.append(element)
      } else if (try? container.superDecoder()) == nil {
        break // cannot advance past the bad element; stop rather than spin
      }
    }
    elements = decoded
  }
}

extension LossyArray: Equatable where Element: Equatable {}
extension LossyArray: Sendable where Element: Sendable {}
