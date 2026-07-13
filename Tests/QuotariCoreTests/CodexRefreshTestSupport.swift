import Foundation
@testable import QuotariCore
import Testing

/// Builds an unsigned JWT whose payload carries the given claims, matching
/// the shape of Codex access tokens (only the `exp` claim is read).
func codexJWT(claims: [String: Any]) -> String {
  func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  let header = base64URL(Data(#"{"alg":"none"}"#.utf8))
  let payload = base64URL((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
  return "\(header).\(payload).sig"
}

func codexAuthPayload(accessToken: String, refreshToken: String? = nil, accountID: String = "acct-1") -> Data {
  var tokens: [String: Any] = ["access_token": accessToken, "account_id": accountID]
  if let refreshToken {
    tokens["refresh_token"] = refreshToken
  }
  return (try? JSONSerialization.data(withJSONObject: ["tokens": tokens])) ?? Data()
}

final class StubCodexRefresher: CodexTokenRefreshing, @unchecked Sendable {
  let result: Result<CodexTokenGrant, Error>

  private let lock = NSLock()
  private var storage: [String] = []

  var calls: [String] {
    lock.withLock { storage }
  }

  init(result: Result<CodexTokenGrant, Error>) {
    self.result = result
  }

  func refresh(refreshToken: String) async throws -> CodexTokenGrant {
    lock.withLock { storage.append(refreshToken) }
    return try result.get()
  }
}

/// Delegates to the real writer after a scripted number of injected failures,
/// so tests can drive the persist-retry path against real registry state.
final class FlakyPersister: CodexCredentialPersisting, @unchecked Sendable {
  struct InjectedFailure: Error {}

  private let inner: CodexCredentialsWriter
  private let lock = NSLock()
  private var failuresRemaining: Int
  private var storage = 0

  var callCount: Int {
    lock.withLock { storage }
  }

  init(inner: CodexCredentialsWriter, failures: Int) {
    self.inner = inner
    failuresRemaining = failures
  }

  func persist(
    _ grant: CodexTokenGrant,
    replacing previousAccessToken: String,
    toRegistryAccount id: String
  ) throws {
    let shouldFail: Bool = lock.withLock {
      storage += 1
      guard failuresRemaining > 0 else { return false }
      failuresRemaining -= 1
      return true
    }
    if shouldFail {
      throw InjectedFailure()
    }
    try inner.persist(grant, replacing: previousAccessToken, toRegistryAccount: id)
  }
}

/// Simulates a re-capture racing the first persist call: it rewrites the
/// registry payload and reports the write as stale, then delegates every
/// later call to the real writer — the mid-transaction race scripted
/// deterministically.
final class RecaptureSimulatingPersister: CodexCredentialPersisting, @unchecked Sendable {
  private let store: CapturedAccountStore
  private let recapturedPayload: Data
  private let inner: CodexCredentialsWriter
  private let lock = NSLock()
  private var simulated = false

  init(store: CapturedAccountStore, recapturedPayload: Data) {
    self.store = store
    self.recapturedPayload = recapturedPayload
    inner = CodexCredentialsWriter(capturedAccounts: store)
  }

  func persist(
    _ grant: CodexTokenGrant,
    replacing previousAccessToken: String,
    toRegistryAccount id: String
  ) throws {
    let simulate: Bool = lock.withLock {
      guard !simulated else { return false }
      simulated = true
      return true
    }
    if simulate {
      try store.updatePayload(id: id) { _ in recapturedPayload }
      throw CodexCredentialPersistError.staleSource
    }
    try inner.persist(grant, replacing: previousAccessToken, toRegistryAccount: id)
  }
}

/// Canned usage payload the strategy's fetch can parse after a refresh.
let codexUsageStubJSON = #"""
{
  "plan_type": "pro",
  "rate_limit": {
    "primary_window": { "used_percent": 73, "reset_at": 1767744000, "limit_window_seconds": 18000 }
  }
}
"""#

/// A fresh in-memory registry holding one saved Codex account with `payload`.
func makeCodexRegistryStore(payload: Data) throws -> CapturedAccountStore {
  let store = CapturedAccountStore(
    keychain: InMemoryKeychain().store,
    service: "Test-Strategy-\(UUID().uuidString)"
  )
  try store.save(CapturedAccount(
    id: "codex:acct-1",
    provider: .codex,
    displayName: "Saved",
    detail: nil,
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .codexAuthFile(path: "/tmp/old.json"),
    payload: payload
  ))
  return store
}

func codexRegistryAccount() -> ProviderAccount {
  ProviderAccount(
    provider: .codex,
    displayName: "Saved",
    detail: "Saved in Quotari",
    credentialSource: .quotariRegistry(id: "codex:acct-1")
  )
}

/// Simulates a stale write whose follow-up reread also fails: the first
/// persist call blinds the registry item's reads and reports staleSource;
/// later calls delegate to the real writer.
final class BlindingPersister: CodexCredentialPersisting, @unchecked Sendable {
  private let keychain: InMemoryKeychain
  private let blindService: String
  private let inner: CodexCredentialsWriter
  private let lock = NSLock()
  private var blinded = false

  init(store: CapturedAccountStore, keychain: InMemoryKeychain, blindService: String) {
    self.keychain = keychain
    self.blindService = blindService
    inner = CodexCredentialsWriter(capturedAccounts: store)
  }

  func persist(
    _ grant: CodexTokenGrant,
    replacing previousAccessToken: String,
    toRegistryAccount id: String
  ) throws {
    let shouldBlind: Bool = lock.withLock {
      guard !blinded else { return false }
      blinded = true
      return true
    }
    if shouldBlind {
      keychain.failReads(of: blindService)
      throw CodexCredentialPersistError.staleSource
    }
    try inner.persist(grant, replacing: previousAccessToken, toRegistryAccount: id)
  }
}

/// Returns 401 for one specific bearer token and 200 (with `json`) for any
/// other — the shape of a server that has revoked a token early.
struct TokenRoutedTransport: ProviderHTTPTransport {
  let deniedToken: String
  let json: String
  let recorder: RefreshStubTransport.Recorder?

  init(deniedToken: String, json: String, recorder: RefreshStubTransport.Recorder? = nil) {
    self.deniedToken = deniedToken
    self.json = json
    self.recorder = recorder
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorder?.record(request)
    let denied = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(deniedToken)"
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: denied ? 401 : 200,
      httpVersion: nil,
      headerFields: nil
    )!
    return (Data(json.utf8), response)
  }
}
