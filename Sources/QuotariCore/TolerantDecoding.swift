import Foundation

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
      value = Date(timeIntervalSince1970: seconds)
    } else if let string = try? container.decode(String.self) {
      value = ISO8601DateFormatter().date(from: string)
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
