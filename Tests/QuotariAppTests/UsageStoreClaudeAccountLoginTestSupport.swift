import Foundation
@testable import Quotari
@testable import QuotariCore

func makeClaudeLoginContext(
  source: InitialClaudeLoginSource = .keychain
) throws -> ClaudeLoginContext {
  let directory = try TemporaryDirectory()
  let registry = CapturedAccountStore.inMemoryForTesting()
  let currentPayload = claudePayload(accessToken: "current-access", refreshToken: "current-refresh")
  let liveCredential = ClaudeLoginPayloadBox(source == .keychain ? currentPayload : nil)
  let credentialDirectory = directory.url.appendingPathComponent(".claude", isDirectory: true)
  let credentialFileURL = credentialDirectory.appendingPathComponent(".credentials.json")
  if source == .credentialsFile {
    try FileManager.default.createDirectory(at: credentialDirectory, withIntermediateDirectories: true)
    try currentPayload.write(to: credentialFileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialFileURL.path)
  }
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { liveCredential.value },
    codexKeychainData: { _, _ in nil },
    capturedAccounts: registry
  )
  let capture = AccountCaptureService(
    capturedAccounts: registry,
    claudeKeychainRead: { _ in liveCredential.value }
  )
  return ClaudeLoginContext(
    directory: directory,
    registry: registry,
    liveCredential: liveCredential,
    credentialFileURL: credentialFileURL,
    discovery: discovery,
    capture: capture,
    profiles: TokenClaudeProfileFetcher(profiles: claudeLoginProfiles())
  )
}

private func claudeLoginProfiles() -> [String: ClaudeProfile] {
  [
    "current-access": ClaudeProfile(
      accountID: "account-current",
      email: "current@example.com",
      organizationID: "organization-current"
    ),
    "added-access": ClaudeProfile(
      accountID: "account-added",
      email: "added@example.com",
      organizationID: "organization-added"
    ),
    "reauthenticated-access": ClaudeProfile(
      accountID: "account-current",
      email: "current@example.com",
      organizationID: "organization-current"
    ),
    "saved-other-access": ClaudeProfile(
      accountID: "account-other",
      email: "other@example.com",
      organizationID: "organization-other"
    ),
    "saved-other-reauthenticated-access": ClaudeProfile(
      accountID: "account-other",
      email: "other@example.com",
      organizationID: "organization-other"
    ),
    "interrupted-access": ClaudeProfile(
      accountID: "account-interrupted",
      email: "interrupted@example.com",
      organizationID: "organization-interrupted"
    ),
    "intervening-access": ClaudeProfile(
      accountID: "account-intervening",
      email: "intervening@example.com",
      organizationID: "organization-intervening"
    ),
    "rotated-current-access": ClaudeProfile(
      accountID: "account-current",
      email: "current@example.com",
      organizationID: "organization-current"
    ),
    "organization-only-access": ClaudeProfile(organizationName: "Example Organization"),
  ]
}

enum InitialClaudeLoginSource {
  case keychain
  case credentialsFile
  case none
}

final class ClaudeLoginPayloadBox: @unchecked Sendable {
  private let lock = NSLock()
  private var payload: Data?

  init(_ payload: Data?) {
    self.payload = payload
  }

  var value: Data? {
    get { lock.withLock { payload } }
    set { lock.withLock { payload = newValue } }
  }
}

struct ClaudeLoginContext: @unchecked Sendable {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let liveCredential: ClaudeLoginPayloadBox
  let credentialFileURL: URL
  let discovery: ProviderAccountDiscovery
  let capture: AccountCaptureService
  let profiles: TokenClaudeProfileFetcher

  @MainActor
  func makeStore(
    login: AccountLoginService,
    accountSwitch: AccountSwitchService? = nil,
    profileFetcher: (any ClaudeProfileFetching)? = nil,
    descriptor: ProviderDescriptor = claudeDescriptorForAutomaticCapture(),
    postCredentialRefreshDelay: Duration = .seconds(30),
    postCredentialRefreshSleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) -> UsageStore {
    UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      accountCapture: capture,
      accountLogin: login,
      automaticallyCapturesDiscoveredAccounts: true,
      accountSwitch: accountSwitch ?? makeSwitcher(),
      profileFetcher: profileFetcher ?? profiles,
      claudeCredentialLoader: loadCredentials,
      postCredentialRefreshDelay: postCredentialRefreshDelay,
      postCredentialRefreshSleep: postCredentialRefreshSleep,
      startsAutomatically: false
    )
  }

  func makeSwitcher(
    activeCLIProcesses: @escaping @Sendable (UsageProvider) throws -> [String] = { _ in [] }
  ) -> AccountSwitchService {
    AccountSwitchService(
      capturedAccounts: registry,
      capture: capture,
      environment: [:],
      home: directory.url,
      keychainRead: { _ in liveCredential.value },
      keychainWrite: { payload, _ in liveCredential.value = payload },
      keychainDelete: { _ in liveCredential.value = nil },
      activeCLIProcesses: activeCLIProcesses
    )
  }

  func loadCredentials(_ source: ProviderCredentialSource) -> ClaudeCredentials? {
    let payload: Data? = switch source {
    case .claudeKeychain:
      liveCredential.value
    case let .claudeCredentialsFile(path):
      try? Data(contentsOf: URL(fileURLWithPath: path))
    case let .quotariRegistry(id):
      registry.account(id: id)?.payload
    case .codexAuthFile, .codexKeychain, .claudeEnvironment:
      nil
    }
    return payload.flatMap { try? ClaudeCredentialsStore.parse($0) }
  }

  func loginObservation(keychainPayload: Data?) -> ClaudeLoginCredentialObservation {
    let accountStateURL = directory.url.appendingPathComponent(".claude.json")
    return ClaudeLoginCredentialObservation(
      keychainPayload: keychainPayload,
      accountState: try? Data(contentsOf: accountStateURL)
    )
  }
}

final class ClaudeLoginBooleanBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

final class ClaudeLoginIntBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

final class ClaudeLoginStringBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String?

  var value: String? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

func countingClaudeDescriptor(
  strategy: AutomaticCaptureCountingStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

func deadDuplicateClaudeLoginDescriptor(ids: Set<String>) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in
      [DeadDuplicateClaudeLoginStrategy(ids: ids)]
    }
  )
}

private struct DeadDuplicateClaudeLoginStrategy: ProviderFetchStrategy {
  let id = "dead-duplicate-login"
  let kind = ProviderFetchKind.oauth
  let ids: Set<String>

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    if case let .quotariRegistry(id) = context.account?.credentialSource,
       ids.contains(id) {
      throw ClaudeTokenRefreshError.reauthenticationRequired
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Stub"
    )
  }
}

actor AccountLoginGatedClaudeProfileFetcher: ClaudeProfileFetching {
  private let gatedAccessToken: String
  private var gatedRequest: Int?
  private let profiles: [String: ClaudeProfile]
  private var matchingRequestCount = 0
  private var requestStarted = false
  private var isReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    gatedAccessToken: String,
    gatedRequest: Int? = 1,
    profiles: [String: ClaudeProfile]
  ) {
    self.gatedAccessToken = gatedAccessToken
    self.gatedRequest = gatedRequest
    self.profiles = profiles
  }

  func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    if accessToken == gatedAccessToken {
      matchingRequestCount += 1
      if matchingRequestCount == gatedRequest {
        requestStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !isReleased {
          await withCheckedContinuation { releaseWaiters.append($0) }
        }
      }
    }
    return profiles[accessToken] ?? ClaudeProfile()
  }

  func armNextRequest() {
    gatedRequest = matchingRequestCount + 1
    requestStarted = false
    isReleased = false
  }

  func waitUntilRequestStarts() async {
    guard !requestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resume() {
    isReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
