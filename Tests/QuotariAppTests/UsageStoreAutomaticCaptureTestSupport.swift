import Foundation
@testable import Quotari
@testable import QuotariCore

struct AutomaticCaptureContext {
  let directory: TemporaryDirectory
  let home: URL
  let authURL: URL
  let registry: CapturedAccountStore
  let discovery: ProviderAccountDiscovery
  let capture: AccountCaptureService
  let selectionStore: ProviderAccountSelectionStore

  @MainActor
  func makeStore() -> UsageStore {
    UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountCapture: capture,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )
  }
}

func makeContext(accountID: String, email: String) throws -> AutomaticCaptureContext {
  let directory = try TemporaryDirectory()
  let home = directory.url
  let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
  try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
  let authURL = codexDirectory.appendingPathComponent("auth.json")
  try writeCodexCredentials(to: authURL, accountID: accountID, email: email)
  let registry = CapturedAccountStore.inMemoryForTesting()
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: home,
    keychainData: { nil },
    codexKeychainData: { _, _ in nil },
    capturedAccounts: registry
  )
  return AutomaticCaptureContext(
    directory: directory,
    home: home,
    authURL: authURL,
    registry: registry,
    discovery: discovery,
    capture: AccountCaptureService(capturedAccounts: registry),
    selectionStore: ProviderAccountSelectionStore(url: home.appendingPathComponent("selection.json"))
  )
}

func writeCodexCredentials(
  to url: URL,
  accountID: String,
  email: String,
  accessToken: String = "access",
  refreshToken: String = "refresh"
) throws {
  let payload =
    #"{"tokens":{"access_token":"\#(accessToken)","account_id":"\#(accountID)","email":"\#(email)","refresh_token":"\#(refreshToken)"}}"#
  try Data(payload.utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func claudeDescriptorForAutomaticCapture() -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(displayName: "Claude", accent: .init(0.8, 0.5, 0.2), supportsWeekly: true),
    pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: AccountRecorder())] }
  )
}

func claudePayload(accessToken: String, refreshToken: String) -> Data {
  Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)"}}"#.utf8
  )
}

func claudePayload(
  accessToken: String,
  refreshToken: String,
  expiresAt: Date
) -> Data {
  let milliseconds = Int(expiresAt.timeIntervalSince1970 * 1000)
  return Data(
    #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)","expiresAt":\#(milliseconds)}}"#
      .utf8
  )
}

final class AutomaticCapturePayloadBox: @unchecked Sendable {
  private let lock = NSLock()
  private var payload: Data

  init(_ payload: Data) {
    self.payload = payload
  }

  var value: Data {
    get { lock.withLock { payload } }
    set { lock.withLock { payload = newValue } }
  }
}

actor GatedCredentialRotationStrategy: ProviderFetchStrategy {
  let id = "gated-credential-rotation"
  let kind = ProviderFetchKind.oauth
  private let payload: AutomaticCapturePayloadBox
  private let rotatedPayload: Data
  private var requestStarted = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var requestContinuation: CheckedContinuation<Void, Never>?

  init(payload: AutomaticCapturePayloadBox, rotatedPayload: Data) {
    self.payload = payload
    self.rotatedPayload = rotatedPayload
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestStarted = true
    requestWaiters.forEach { $0.resume() }
    requestWaiters.removeAll()
    await withCheckedContinuation { requestContinuation = $0 }
    let credentials = try ClaudeCredentialsStore.parse(rotatedPayload)
    let finalAccount = ProviderAccount(
      provider: context.provider,
      displayName: "Claude Code",
      detail: nil,
      credentialSource: context.account?.credentialSource ?? .claudeKeychain(
        service: ClaudeCredentialsStore.keychainService
      ),
      credentialIdentity: credentials.accessToken
    )
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Rotated",
      credentialScopeID: finalAccount.credentialScopeID,
      credentialTransitionSourceScopeIDs: Set([context.account?.credentialScopeID].compactMap(\.self))
    )
  }

  func waitUntilRequestStarts() async {
    guard !requestStarted else { return }
    await withCheckedContinuation { requestWaiters.append($0) }
  }

  func resumeWithRotatedPayload() {
    payload.value = rotatedPayload
    requestContinuation?.resume()
    requestContinuation = nil
  }
}

actor AutomaticCaptureCountingStrategy: ProviderFetchStrategy {
  nonisolated let id = "automatic-capture-counting"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var requestCount = 0
  private(set) var interactions: [ProviderFetchInteraction] = []

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    interactions.append(context.interaction)
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Counted"
    )
  }
}

func countingCodexDescriptor(
  strategy: AutomaticCaptureCountingStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .codex,
    metadata: ProviderMetadata(
      displayName: "Codex",
      accent: .init(0.2, 0.4, 0.6),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

struct StableClaudeProfileFetcher: ClaudeProfileFetching {
  let accountID: String
  let email: String

  func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    ClaudeProfile(accountID: accountID, email: email)
  }
}

struct TokenClaudeProfileFetcher: ClaudeProfileFetching {
  let profiles: [String: ClaudeProfile]

  func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    profiles[accessToken] ?? ClaudeProfile()
  }
}

actor CancellableProviderFetchStrategy: ProviderFetchStrategy {
  nonisolated let id = "cancellable-provider-fetch"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var wasCancelled = false
  private var requestStarted = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestStarted = true
    requestWaiters.forEach { $0.resume() }
    requestWaiters.removeAll()
    do {
      try await Task.sleep(for: .seconds(30))
    } catch is CancellationError {
      wasCancelled = true
      throw CancellationError()
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Unexpected"
    )
  }

  func waitUntilRequestStarts() async {
    guard !requestStarted else { return }
    await withCheckedContinuation { requestWaiters.append($0) }
  }
}

actor GatedPostCaptureDiscovery: ProviderAccountDiscovering {
  private let discovery: ProviderAccountDiscovery
  private var accountRequestCount = 0
  private var verificationReadStarted = false
  private var verificationReadReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(_ discovery: ProviderAccountDiscovery) {
    self.discovery = discovery
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    accountRequestCount += 1
    if accountRequestCount == 2 {
      verificationReadStarted = true
      startWaiters.forEach { $0.resume() }
      startWaiters.removeAll()
      if !verificationReadReleased {
        await withCheckedContinuation { releaseWaiters.append($0) }
      }
    }
    return await discovery.accounts(for: provider)
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    await discovery.liveAccount(equivalentTo: account, among: accounts)
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    await discovery.capturedCopies(among: accounts)
  }

  func waitUntilVerificationReadStarts() async {
    guard !verificationReadStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resumeVerificationRead() {
    verificationReadReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
