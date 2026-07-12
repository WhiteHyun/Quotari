import Foundation
@testable import QuotariCore

/// A canned HTTP transport for token-refresh tests: fixed body/status,
/// records every request (lock-guarded, tests fetch concurrently).
struct RefreshStubTransport: ProviderHTTPTransport {
  let body: Data
  let status: Int
  let recorder: Recorder?

  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
      lock.withLock { storage }
    }

    func record(_ request: URLRequest) {
      lock.withLock { storage.append(request) }
    }
  }

  init(json: String, status: Int = 200, recorder: Recorder? = nil) {
    body = Data(json.utf8)
    self.status = status
    self.recorder = recorder
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorder?.record(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: nil
    )!
    return (body, response)
  }
}

final class StubRefresher: ClaudeTokenRefreshing, @unchecked Sendable {
  let result: Result<ClaudeTokenGrant, Error>
  let delay: Duration?
  /// Runs before the result is returned — lets tests mutate the credential
  /// source mid-refresh to simulate Claude Code racing us.
  let onRefresh: (@Sendable () -> Void)?

  private let lock = NSLock()
  private var storage: [String] = []

  var calls: [String] {
    lock.withLock { storage }
  }

  init(
    result: Result<ClaudeTokenGrant, Error>,
    delay: Duration? = nil,
    onRefresh: (@Sendable () -> Void)? = nil
  ) {
    self.result = result
    self.delay = delay
    self.onRefresh = onRefresh
  }

  func refresh(refreshToken: String, scopes: [String], now: Date) async throws -> ClaudeTokenGrant {
    lock.withLock { storage.append(refreshToken) }
    if let delay {
      try await Task.sleep(for: delay)
    }
    onRefresh?()
    return try result.get()
  }
}

final class RecordingPersister: ClaudeCredentialPersisting, @unchecked Sendable {
  struct PersistCall {
    var grant: ClaudeTokenGrant
    var previousAccessToken: String
    var source: ProviderCredentialSource
  }

  let error: Error?
  private let lock = NSLock()
  private var storage: [PersistCall] = []

  var persisted: [PersistCall] {
    lock.withLock { storage }
  }

  init(error: Error? = nil) {
    self.error = error
  }

  func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws {
    lock.withLock {
      storage.append(PersistCall(grant: grant, previousAccessToken: previousAccessToken, source: source))
    }
    if let error {
      throw error
    }
  }
}
