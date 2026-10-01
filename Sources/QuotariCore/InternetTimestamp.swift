import Foundation

/// Every Claude and Codex log row carries an RFC 3339 timestamp, and even a
/// shared `ISO8601DateFormatter` spends most of a log parse inside ICU. This
/// parses exactly `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` with integer
/// math and returns nil for anything else, so callers fall back to the
/// formatters. Fractions keep milliseconds, truncated, as those formatters do.
enum InternetTimestamp {
  static func parse(_ string: String) -> Date? {
    var string = string
    return string.withUTF8 { parse($0) }
  }

  private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
    guard bytes.count >= 20,
          bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
          bytes[10] == UInt8(ascii: "T"),
          bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
          let year = number(bytes, 0, 4), let month = number(bytes, 5, 2), let day = number(bytes, 8, 2),
          let hour = number(bytes, 11, 2), let minute = number(bytes, 14, 2), let second = number(bytes, 17, 2),
          (1 ... 12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
          hour <= 23, minute <= 59, second <= 59
    else { return nil }

    guard let (milliseconds, zoneStart) = fraction(bytes, from: 19),
          let offsetSeconds = zoneOffset(bytes, from: zoneStart)
    else { return nil }

    let days = daysFromCivil(year: year, month: month, day: day)
    let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
    return Date(timeIntervalSince1970: Double(seconds * 1000 + milliseconds) / 1000)
  }

  /// Milliseconds from an optional `.digits` run, and where the zone begins.
  private static func fraction(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> (Int, Int)? {
    guard start < bytes.count, bytes[start] == UInt8(ascii: ".") else { return (0, start) }
    var index = start + 1
    var milliseconds = 0
    while index < bytes.count, let digit = digit(bytes[index]) {
      if index - start <= 3 {
        milliseconds = milliseconds * 10 + digit
      }
      index += 1
    }
    let digits = index - start - 1
    guard digits > 0 else { return nil }
    for _ in 0 ..< max(0, 3 - digits) {
      milliseconds *= 10
    }
    return (milliseconds, index)
  }

  /// Seconds east of UTC for a trailing `Z` or `±HH:MM` that ends the string.
  private static func zoneOffset(_ bytes: UnsafeBufferPointer<UInt8>, from index: Int) -> Int? {
    guard index < bytes.count else { return nil }
    switch bytes[index] {
    case UInt8(ascii: "Z"):
      return index + 1 == bytes.count ? 0 : nil
    case UInt8(ascii: "+"), UInt8(ascii: "-"):
      guard bytes.count - index == 6, bytes[index + 3] == UInt8(ascii: ":"),
            let hours = number(bytes, index + 1, 2), let minutes = number(bytes, index + 4, 2),
            hours <= 23, minutes <= 59
      else { return nil }
      let magnitude = hours * 3600 + minutes * 60
      return bytes[index] == UInt8(ascii: "+") ? magnitude : -magnitude
    default:
      return nil
    }
  }

  private static func digit(_ byte: UInt8) -> Int? {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") ? Int(byte - UInt8(ascii: "0")) : nil
  }

  private static func number(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ length: Int) -> Int? {
    var value = 0
    for offset in 0 ..< length {
      guard let digit = digit(bytes[start + offset]) else { return nil }
      value = value * 10 + digit
    }
    return value
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2:
      year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11:
      30
    default:
      31
    }
  }

  /// Days since 1970-01-01 in the proleptic Gregorian calendar (Hinnant's algorithm).
  private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }
}
