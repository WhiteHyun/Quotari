import Foundation

/// The seam between fetch strategies and the network, so tests can inject a
/// stub instead of hitting real endpoints. `URLSession` conforms in production.
public protocol ProviderHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum ProviderHTTPError: LocalizedError, Sendable {
  case nonHTTPResponse
  case unauthorized
  case status(Int)

  public var errorDescription: String? {
    switch self {
    case .nonHTTPResponse: "The server returned a non-HTTP response."
    case .unauthorized: "Authentication failed (401/403)."
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
    switch response.statusCode {
    case 200 ..< 300: return data
    case 401, 403: throw ProviderHTTPError.unauthorized
    default: throw ProviderHTTPError.status(response.statusCode)
    }
  }
}
