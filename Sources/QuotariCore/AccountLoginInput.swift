import Darwin
import Foundation

public enum AccountLoginInputError: Equatable, LocalizedError, Sendable {
  case emptyAuthenticationCode
  case multilineAuthenticationCode
  case inputUnavailable

  public var errorDescription: String? {
    switch self {
    case .emptyAuthenticationCode:
      "Enter the authentication code from the browser."
    case .multilineAuthenticationCode:
      "Enter a single authentication code without line breaks."
    case .inputUnavailable:
      "Authentication code entry is no longer available. Start the account login again."
    }
  }
}

/// A short-lived input channel for an interactive provider login process.
/// Submitted authentication codes are written directly to the CLI stdin and
/// are never retained after the write completes.
public final class AccountLoginInput: @unchecked Sendable {
  private let lock = NSLock()
  private var writer: FileHandle?
  private var isFinished = false

  public init() {}

  public func submit(authenticationCode: String) throws {
    let code = authenticationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else {
      throw AccountLoginInputError.emptyAuthenticationCode
    }
    guard !code.contains(where: \.isNewline) else {
      throw AccountLoginInputError.multilineAuthenticationCode
    }
    let data = Data("\(code)\n".utf8)
    try lock.withLock {
      guard !isFinished, let writer else {
        throw AccountLoginInputError.inputUnavailable
      }
      do {
        try writer.write(contentsOf: data)
      } catch {
        isFinished = true
        self.writer = nil
        try? writer.close()
        throw AccountLoginInputError.inputUnavailable
      }
    }
  }

  var isConnected: Bool {
    lock.withLock { !isFinished && writer != nil }
  }

  func connect(_ writer: FileHandle) throws {
    guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw AccountLoginInputError.inputUnavailable
    }
    try lock.withLock {
      guard !isFinished, self.writer == nil else {
        throw AccountLoginInputError.inputUnavailable
      }
      self.writer = writer
    }
  }

  func finish() {
    let writer = lock.withLock {
      isFinished = true
      defer { self.writer = nil }
      return self.writer
    }
    try? writer?.close()
  }
}
