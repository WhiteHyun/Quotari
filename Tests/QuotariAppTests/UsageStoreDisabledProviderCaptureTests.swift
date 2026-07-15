import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreDisabledProviderCaptureTests {
  @Test func scanDoesNotCaptureAccountsForDisabledProvider() async throws {
    let directory = try TemporaryDirectory()
    let payload = Data(
      #"{"claudeAiOauth":{"accessToken":"claude-access","refreshToken":"claude-refresh"}}"#.utf8
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload },
      capturedAccounts: registry
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in payload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )
    store.setProviderEnabled(.claude, enabled: false)

    await store.reloadAccounts()

    #expect(registry.load().isEmpty)
    #expect(store.accounts[.claude]?.isEmpty == false)
    #expect(store.capturedEquivalents.isEmpty)
  }
}
