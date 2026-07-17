import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAccountLoginInputTests {
  @Test func terminalOutputSanitizerStripsSplitANSIAndOSCSequences() {
    var sanitizer = AccountLoginOutputSanitizer()

    let first = sanitizer.append("Opening \u{001B}]8;;https://example")
    let second = sanitizer.append(".com\u{001B}\\link\u{001B}[31")
    let third = sanitizer.append("m red\u{001B}[0m\n")

    #expect(first + second + third == "Opening link red\n")
  }

  @Test func terminalOutputSanitizerNormalizesCarriageReturnsAndDropsControls() {
    var sanitizer = AccountLoginOutputSanitizer()

    #expect(sanitizer.append("first\rsecond\r\nthird\u{0001}\tvalue") == "first\nsecond\nthird\tvalue")
  }

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

  @Test func rejectedAuthenticationCodeCanBeSubmittedAgain() async throws {
    let receivedCodes = AuthenticationCodesRecorder()
    let registry = CapturedAccountStore.inMemoryForTesting()
    let login = AccountLoginService(interactiveOperation: { provider, onOutput, input, _, _ in
      let input = try #require(input)
      let pipe = Pipe()
      try input.connect(pipe.fileHandleForWriting)
      await onOutput?("Paste code here if prompted > ")
      let first = await Task.detached {
        pipe.fileHandleForReading.availableData
      }.value
      await receivedCodes.record(String(data: first, encoding: .utf8) ?? "")
      await onOutput?("Invalid code. Paste code here if prompted > ")
      let second = await Task.detached {
        pipe.fileHandleForReading.availableData
      }.value
      input.finish()
      await receivedCodes.record(String(data: second, encoding: .utf8) ?? "")
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
    try await waitForAuthenticationCodePrompt(in: store)

    #expect(store.submitAccountLoginAuthenticationCode("first-code", for: .codex))
    #expect(store.accountLoginPhases[.codex] == .completingLogin)
    try await waitForAuthenticationCodePrompt(in: store)
    #expect(store.submitAccountLoginAuthenticationCode("second-code", for: .codex))
    await loginTask.value

    #expect(await receivedCodes.values == ["first-code\n", "second-code\n"])
    #expect(registry.load().map(\.id) == ["codex:added-account"])
  }

  private func waitForAuthenticationCodePrompt(in store: UsageStore) async throws {
    for _ in 0 ..< 100 {
      guard store.accountLoginPhases[.codex] != .waitingForAuthenticationCode else { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("authentication code prompt did not appear")
  }

  @Test func successfulBrowserLoginLeavesAuthenticationCodePhaseWithoutSubmitting() async throws {
    let completion = AccountLoginCompletionGate()
    let registry = CapturedAccountStore.inMemoryForTesting()
    let login = AccountLoginService(interactiveOperation: { provider, onOutput, input, _, _ in
      await onOutput?("Paste code here if prompted > ")
      await onOutput?("Login successful.\n")
      await onOutput?("Paste code here if prompted > ")
      await completion.wait()
      input?.finish()
      return AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "browser-account")
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
      guard store.accountLoginPhases[.codex] != .completingLogin else { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(store.accountLoginPhases[.codex] == .completingLogin)
    #expect(!store.submitAccountLoginAuthenticationCode("stale-code", for: .codex))
    #expect(store.accountLoginErrors[.codex] == nil)

    await completion.release()
    await loginTask.value
    #expect(registry.load().map(\.id) == ["codex:browser-account"])
  }

  @Test func successfulLoginAfterCodeSubmissionIgnoresAStalePrompt() async throws {
    let outputDelivered = AccountLoginCompletionGate()
    let loginCompletion = AccountLoginCompletionGate()
    let registry = CapturedAccountStore.inMemoryForTesting()
    let login = AccountLoginService(interactiveOperation: { provider, onOutput, input, _, _ in
      let input = try #require(input)
      let pipe = Pipe()
      try input.connect(pipe.fileHandleForWriting)
      await onOutput?("Paste code here if prompted > ")
      _ = await Task.detached {
        pipe.fileHandleForReading.availableData
      }.value
      await onOutput?("Login successful.\n")
      await onOutput?("Paste code here if prompted > ")
      await outputDelivered.release()
      await loginCompletion.wait()
      input.finish()
      return AccountLoginResult(
        provider: provider,
        origin: .codexAuthFile(path: "/isolated/auth.json"),
        payload: codexLoginPayload(accountID: "submitted-account")
      )
    })
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      accountLogin: login,
      startsAutomatically: false
    )
    let loginTask = Task { await store.addAccount(for: .codex) }
    try await waitForAuthenticationCodePrompt(in: store)

    #expect(store.submitAccountLoginAuthenticationCode("submitted-code", for: .codex))
    await outputDelivered.wait()
    #expect(store.accountLoginPhases[.codex] == .completingLogin)
    #expect(!store.submitAccountLoginAuthenticationCode("stale-code", for: .codex))

    await loginCompletion.release()
    await loginTask.value
    #expect(registry.load().map(\.id) == ["codex:submitted-account"])
  }
}

private actor AuthenticationCodeRecorder {
  private(set) var value = ""

  func record(_ value: String) {
    self.value = value
  }
}

private actor AuthenticationCodesRecorder {
  private(set) var values: [String] = []

  func record(_ value: String) {
    values.append(value)
  }
}

private actor AccountLoginCompletionGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isReleased = false

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    isReleased = true
    continuation?.resume()
    continuation = nil
  }
}
