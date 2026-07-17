import Foundation

/// The seam between fetch strategies and the network, so tests can inject a
/// stub instead of hitting real endpoints. `URLSession` conforms in production.
public protocol ProviderHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum ProviderHTTPError: LocalizedError, Sendable {
  case nonHTTPResponse
  case unauthorized
  case rateLimited(retryAfter: Date?)
  case status(Int)

  public var errorDescription: String? {
    switch self {
    case .nonHTTPResponse: "The server returned a non-HTTP response."
    case .unauthorized: "Authentication failed (401/403)."
    case .rateLimited:
      "Usage data is temporarily rate limited. Quotari will retry automatically, or click Refresh to try now."
    case let .status(code): "The server returned HTTP \(code)."
    }
  }
}

extension URLSession: ProviderHTTPTransport {
  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request, delegate: nil)
    guard let http = response as? HTTPURLResponse else { throw ProviderHTTPError.nonHTTPResponse }
    return (data, http)
  }
}

public extension ProviderHTTPTransport {
  /// Performs a GET with bearer auth + extra headers, mapping auth failures to a
  /// typed error so strategies can decide whether to fall back.
  func getJSON(
    url: URL,
    bearer: String,
    headers: [String: String] = [:]
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, response) = try await data(for: request)
    return try payload(data: data, response: response)
  }

  /// Performs an unauthenticated JSON POST (e.g. an OAuth token exchange),
  /// with the same status-to-error mapping as `getJSON`.
  func postJSON(
    url: URL,
    body: Data,
    headers: [String: String] = [:]
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, response) = try await data(for: request)
    return try payload(data: data, response: response)
  }

  private func payload(data: Data, response: HTTPURLResponse) throws -> Data {
    switch response.statusCode {
    case 200 ..< 300: return data
    case 401, 403: throw ProviderHTTPError.unauthorized
    case 429:
      throw ProviderHTTPError.rateLimited(
        retryAfter: retryAfterDate(from: response)
      )
    default: throw ProviderHTTPError.status(response.statusCode)
    }
  }

  private func retryAfterDate(
    from response: HTTPURLResponse,
    now: Date = Date()
  ) -> Date? {
    guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else { return nil }

    if let seconds = TimeInterval(raw), seconds >= 0 {
      return now.addingTimeInterval(seconds)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    return formatter.date(from: raw)
  }
}
