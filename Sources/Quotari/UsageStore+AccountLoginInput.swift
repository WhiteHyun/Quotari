import Foundation
import QuotariCore

extension UsageStore {
  @discardableResult
  func submitAccountLoginAuthenticationCode(_ code: String, for provider: UsageProvider) -> Bool {
    guard accountLoginPhases[provider] == .waitingForAuthenticationCode,
          let input = accountLoginInputs[provider]
    else {
      accountLoginErrors[provider] = AccountLoginInputError.inputUnavailable.localizedDescription
      return false
    }
    do {
      try input.submit(authenticationCode: code)
      accountLoginErrors[provider] = nil
      accountLoginPhases[provider] = .completingLogin
      return true
    } catch {
      accountLoginErrors[provider] = error.localizedDescription
      return false
    }
  }

  func performAccountLogin(
    for provider: UsageProvider,
    previousClaudeLogin: PreservedClaudeLogin?,
    registryBaseline: AccountLoginRegistryBaseline?
  ) async throws -> AccountLoginResult {
    accountLoginPhases[provider] = .waitingForBrowser
    let input = AccountLoginInput()
    accountLoginInputs[provider] = input
    defer { accountLoginInputs[provider] = nil }
    let login = accountLogin
    let result = try await login.login(
      provider: provider,
      onOutput: { [weak self] output in
        await self?.appendAccountLoginOutput(output, for: provider)
      },
      input: input,
      beforeCredentialOverwrite: { [weak self] provider, source, payload in
        guard let self else { throw CancellationError() }
        try await preserveCredentialImmediatelyBeforeLogin(
          provider: provider,
          source: source,
          payload: payload,
          previousClaudeLogin: previousClaudeLogin,
          registryBaseline: registryBaseline
        )
      },
      onCredentialMutationPossible: {
        registryBaseline?.markCredentialMutationPossible()
      },
      onCredentialObserved: { payload in
        registryBaseline?.recordClaudePostLoginKeychain(payload)
      }
    )
    registryBaseline?.recordClaudePostLoginKeychain(result.payload)
    return result
  }

  private func appendAccountLoginOutput(_ output: String, for provider: UsageProvider) {
    var sanitizer = accountLoginOutputSanitizers[provider] ?? AccountLoginOutputSanitizer()
    let sanitized = sanitizer.append(output)
    accountLoginOutputSanitizers[provider] = sanitizer
    let previous = accountLoginOutputs[provider] ?? ""
    let combined = previous + sanitized
    accountLoginOutputs[provider] = String(combined.suffix(12000))
    let authenticationCodePrompt = "Paste code here"
    let recentOutput = String(previous.suffix(authenticationCodePrompt.count - 1)) + sanitized
    let phase = accountLoginPhases[provider]
    if phase == .waitingForBrowser || phase == .completingLogin,
       recentOutput.localizedCaseInsensitiveContains(authenticationCodePrompt) {
      accountLoginPhases[provider] = .waitingForAuthenticationCode
    }
  }
}

struct AccountLoginOutputSanitizer {
  private enum State {
    case text
    case escape
    case controlSequence
    case operatingSystemCommand
    case operatingSystemCommandEscape
  }

  private var state = State.text
  private var lastOutputWasNewline = false

  mutating func append(_ output: String) -> String {
    var sanitized = String.UnicodeScalarView()
    for scalar in output.unicodeScalars {
      switch state {
      case .text:
        appendText(scalar, to: &sanitized)
      case .escape:
        consumeEscape(scalar)
      case .controlSequence:
        consumeControlSequence(scalar)
      case .operatingSystemCommand:
        consumeOperatingSystemCommand(scalar)
      case .operatingSystemCommandEscape:
        consumeOperatingSystemCommandEscape(scalar)
      }
    }
    return String(sanitized)
  }

  private mutating func appendText(
    _ scalar: Unicode.Scalar,
    to output: inout String.UnicodeScalarView
  ) {
    switch scalar.value {
    case 0x1B:
      state = .escape
    case 0x0A:
      if !lastOutputWasNewline {
        output.append(scalar)
      }
      lastOutputWasNewline = true
    case 0x0D:
      if !lastOutputWasNewline {
        output.append("\n")
        lastOutputWasNewline = true
      }
    case 0x09, 0x20...:
      output.append(scalar)
      lastOutputWasNewline = false
    default:
      break
    }
  }

  private mutating func consumeEscape(_ scalar: Unicode.Scalar) {
    if scalar.value == 0x5B {
      state = .controlSequence
    } else if scalar.value == 0x5D {
      state = .operatingSystemCommand
    } else {
      state = .text
    }
  }

  private mutating func consumeControlSequence(_ scalar: Unicode.Scalar) {
    if 0x40 ... 0x7E ~= scalar.value {
      state = .text
    }
  }

  private mutating func consumeOperatingSystemCommand(_ scalar: Unicode.Scalar) {
    if scalar.value == 0x07 {
      state = .text
    } else if scalar.value == 0x1B {
      state = .operatingSystemCommandEscape
    }
  }

  private mutating func consumeOperatingSystemCommandEscape(_ scalar: Unicode.Scalar) {
    if scalar.value == 0x5C || scalar.value == 0x07 {
      state = .text
    } else if scalar.value != 0x1B {
      state = .operatingSystemCommand
    }
  }
}
