import Foundation
@testable import Quotari
@testable import QuotariCore

struct WeakIdentityRotationFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let store: UsageStore
  let weakIdentity: ClaudeAccountIdentity
  let expectedIDs: [String]
}

@MainActor
func makeWeakIdentityRotationFixture() throws -> WeakIdentityRotationFixture {
  let directory = try TemporaryDirectory()
  let savedPayload = claudePayload(
    accessToken: "saved-generation-access",
    refreshToken: "saved-generation-refresh"
  )
  let livePayload = claudePayload(
    accessToken: "rotated-generation-access",
    refreshToken: "rotated-generation-refresh"
  )
  let weakIdentity = ClaudeAccountIdentity(
    accountID: "weak-account",
    email: "weak@example.com"
  )
  let registry = CapturedAccountStore.inMemoryForTesting()
  try registry.save(CapturedAccount(
    id: "claude:saved",
    provider: .claude,
    displayName: "weak@example.com",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: savedPayload,
    claudeAccountIdentity: weakIdentity
  ))
  let generatedID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
  let store = weakIdentityRotationStore(
    directory: directory,
    registry: registry,
    livePayload: livePayload,
    weakIdentity: weakIdentity,
    generatedID: generatedID
  )
  return WeakIdentityRotationFixture(
    directory: directory,
    registry: registry,
    store: store,
    weakIdentity: weakIdentity,
    expectedIDs: [
      "claude:\(generatedID.uuidString.lowercased())",
      "claude:saved",
    ]
  )
}

@MainActor
private func weakIdentityRotationStore(
  directory: TemporaryDirectory,
  registry: CapturedAccountStore,
  livePayload: Data,
  weakIdentity: ClaudeAccountIdentity,
  generatedID: UUID
) -> UsageStore {
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { livePayload },
    capturedAccounts: registry
  )
  return UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in livePayload },
      makeUUID: { generatedID }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "saved-generation-access": weakProfile(identity: weakIdentity),
      "rotated-generation-access": weakProfile(identity: weakIdentity),
    ]),
    claudeCredentialLoader: { source in
      automaticCaptureClaudeCredentials(
        source: source,
        keychainPayload: livePayload,
        registry: registry
      )
    },
    startsAutomatically: false
  )
}

private func weakProfile(identity: ClaudeAccountIdentity) -> ClaudeProfile {
  ClaudeProfile(accountID: identity.accountID, email: identity.email)
}
