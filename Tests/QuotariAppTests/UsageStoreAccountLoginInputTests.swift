import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAccountLoginInputTests {
  @Test func authenticationCodePromptCanBeSubmittedToTheActiveLogin() async throws {
    let receivedCode = AuthenticationCodeRecorder()
    let registry = CapturedAccountStore.inMemoryForTesting()
    let login = AccountLoginService(interactiveOperation: { provider, onOutput, input, _, _ in
      let input = try #require(input)
      let pipe = Pipe()
      try input.connect(pipe.fileHandleForWriting)
      await onOutput?("Paste code here if prompted > ")
      let data = await Task.detached {
        pipe.fileHandleForReading.availableData
      }.value
      input.finish()
      await receivedCode.record(String(data: data, encoding: .utf8) ?? "")
      return AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "added-account")
      )
    })
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      accountLogin: login,
      startsAutomatically: false
    )
    let loginTask = Task { await store.addAccount(for: .codex) }
    for _ in 0 ..< 100 {
      guard store.accountLoginPhases[.codex] != .waitingForAuthenticationCode else { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(store.accountLoginPhases[.codex] == .waitingForAuthenticationCode)
    #expect(store.submitAccountLoginAuthenticationCode(" auth-code-123 ", for: .codex))
    #expect(store.accountLoginPhases[.codex] == .completingLogin)
    await loginTask.value

    #expect(await receivedCode.value == "auth-code-123\n")
    #expect(registry.load().map(\.id) == ["codex:added-account"])
    #expect(store.accountLoginInputs[.codex] == nil)
  }
}

private actor AuthenticationCodeRecorder {
  private(set) var value = ""

  func record(_ value: String) {
    self.value = value
  }
}
