import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAccountLoginTests {
  @Test func successfulLoginIsImmediatelyAddedToTheRegistry() async throws {
    let registry = CapturedAccountStore.inMemoryForTesting()
    let capture = AccountCaptureService(capturedAccounts: registry)
    let login = AccountLoginService { provider in
      AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "added-account")
      )
    }
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountCapture: capture,
      accountLogin: login,
      startsAutomatically: false
    )

    await store.addAccount(for: .codex)

    let added = try #require(registry.load().first)
    #expect(added.id == "codex:added-account")
    #expect(store.accountLoginErrors[.codex] == nil)
    #expect(store.addingAccountProviders.isEmpty)
    #expect(store.accountLoginPhases[.codex] == nil)
    #expect(store.selectedAccounts[.codex]?.id == added.providerAccount.id)
    #expect(store.monitoredAccounts[.codex]?.map(\.id) == [added.providerAccount.id])
  }

  @Test func duplicateLoginUpdatesWithoutAddingAnotherRow() async throws {
    let registry = CapturedAccountStore.inMemoryForTesting()
    let capture = AccountCaptureService(capturedAccounts: registry)
    _ = try capture.captureRawPayload(
      provider: .codex,
      origin: .codexAuthFile(path: "/first/auth.json"),
      payload: codexLoginPayload(accountID: "same-account", accessToken: "first"),
      now: Date(timeIntervalSince1970: 1)
    )
    let login = AccountLoginService { provider in
      AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "same-account", accessToken: "second")
      )
    }
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountCapture: capture,
      accountLogin: login,
      startsAutomatically: false
    )

    await store.addAccount(for: .codex)

    let saved = registry.load()
    #expect(saved.count == 1)
    let credentials = try CodexCredentialsStore.parse(#require(saved.first).payload)
    #expect(credentials.accessToken == "second")
  }

  @Test func reauthenticatingSelectedCodexAccountRefreshesUsageImmediately() async throws {
    let registry = CapturedAccountStore.inMemoryForTesting()
    let capture = AccountCaptureService(capturedAccounts: registry)
    let captured = try capture.captureRawPayload(
      provider: .codex,
      origin: .codexAuthFile(path: "/first/auth.json"),
      payload: codexLoginPayload(accountID: "same-account", accessToken: "first"),
      now: Date(timeIntervalSince1970: 1)
    )
    let selected = try #require(captured)
    let strategy = AutomaticCaptureCountingStrategy()
    let login = AccountLoginService { provider in
      AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "same-account", accessToken: "second")
      )
    }
    let store = UsageStore.isolatedForTesting(
      providers: [countingCodexDescriptor(strategy: strategy)],
      accountCapture: capture,
      accountLogin: login,
      startsAutomatically: false
    )
    store.selectAccount(selected.providerAccount, for: .codex)
    await store.selectionRefreshTasks[.codex]?.value
    let requestsBeforeLogin = await strategy.requestCount

    await store.addAccount(for: .codex)
    await store.selectionRefreshTasks[.codex]?.value

    #expect(await strategy.requestCount == requestsBeforeLogin + 1)
  }

  @Test func loginFailureLeavesExistingRegistryUntouched() async throws {
    let registry = CapturedAccountStore.inMemoryForTesting()
    let capture = AccountCaptureService(capturedAccounts: registry)
    _ = try capture.captureRawPayload(
      provider: .codex,
      origin: .codexAuthFile(path: "/existing/auth.json"),
      payload: codexLoginPayload(accountID: "existing"),
      now: Date(timeIntervalSince1970: 1)
    )
    let login = AccountLoginService { provider in
      throw AccountLoginError.commandFailed(provider, status: 1)
    }
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountCapture: capture,
      accountLogin: login,
      startsAutomatically: false
    )

    await store.addAccount(for: .codex)

    #expect(registry.load().map(\.id) == ["codex:existing"])
    #expect(store.accountLoginErrors[.codex]?.contains("status 1") == true)
  }

  @Test func loginOutputIsVisibleAlongsideFailure() async {
    let login = AccountLoginService(streamingOperation: { provider, onOutput in
      await onOutput?("If your browser did not open, visit https://example.com/device\n")
      throw AccountLoginError.commandFailed(provider, status: 1)
    })
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountLogin: login,
      startsAutomatically: false
    )

    await store.addAccount(for: .codex)

    #expect(store.accountLoginOutputs[.codex]?.contains("https://example.com/device") == true)
    #expect(store.accountLoginErrors[.codex]?.contains("status 1") == true)
  }

  @Test func unrenewableLoginIsRejected() async {
    let registry = CapturedAccountStore.inMemoryForTesting()
    let login = AccountLoginService { provider in
      AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: Data(#"{"tokens":{"access_token":"access"}}"#.utf8)
      )
    }
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      accountLogin: login,
      startsAutomatically: false
    )

    await store.addAccount(for: .codex)

    #expect(registry.load().isEmpty)
    #expect(store.accountLoginErrors[.codex]?.contains("renewable") == true)
  }

  @Test func currentCLIAccountIsManagedBeforeLoginStarts() async throws {
    let context = try makeContext(accountID: "current-account", email: "current@example.com")
    let registry = context.registry
    let login = AccountLoginService { provider in
      #expect(registry.load().map(\.id) == ["codex:current-account"])
      return AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "added-account")
      )
    }
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: context.discovery,
      accountSelectionStore: context.selectionStore,
      accountCapture: context.capture,
      accountLogin: login,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    await store.addAccount(for: .codex)

    #expect(Set(registry.load().map(\.id)) == ["codex:current-account", "codex:added-account"])
  }

  @Test func disabledProviderStillPreservesCurrentCLIAccountBeforeLoginStarts() async throws {
    let context = try makeContext(accountID: "current-account", email: "current@example.com")
    let registry = context.registry
    let login = AccountLoginService { provider in
      #expect(registry.load().map(\.id) == ["codex:current-account"])
      return AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "added-account")
      )
    }
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: context.discovery,
      accountSelectionStore: context.selectionStore,
      accountCapture: context.capture,
      accountLogin: login,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )
    store.setProviderEnabled(.codex, enabled: false)

    await store.addAccount(for: .codex)

    #expect(Set(registry.load().map(\.id)) == ["codex:current-account", "codex:added-account"])
  }

  @Test func preservationFailureBlocksLogin() async throws {
    let context = try makeContext(accountID: "current-account", email: "current@example.com")
    try Data(#"{"tokens":{"access_token":"access","account_id":"current-account"}}"#.utf8)
      .write(to: context.authURL)
    let calls = AccountLoginCallCounter()
    let login = AccountLoginService { provider in
      await calls.record()
      return AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "added-account")
      )
    }
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: context.discovery,
      accountSelectionStore: context.selectionStore,
      accountCapture: context.capture,
      accountLogin: login,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    await store.addAccount(for: .codex)

    #expect(await calls.value == 0)
    #expect(context.registry.load().isEmpty)
    #expect(store.accountLoginErrors[.codex]?.contains("preserve") == true)
  }
}

private actor AccountLoginCallCounter {
  private(set) var value = 0

  func record() {
    value += 1
  }
}

func codexLoginPayload(
  accountID: String,
  accessToken: String = "access",
  refreshToken: String = "refresh"
) -> Data {
  Data(
    #"{"tokens":{"access_token":"\#(accessToken)","account_id":"\#(accountID)","refresh_token":"\#(refreshToken)"}}"#
      .utf8
  )
}
