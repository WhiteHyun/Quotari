import Foundation

/// Reads and writes generic-password keychain items. In production the
/// operations shell out to the `security` CLI rather than Security.framework:
/// the ACL consent then sticks to the stable system binary, so rebuilt dev
/// binaries don't re-prompt every run (the same rationale the Claude
/// credential reader already relies on). The operations are injectable so
/// tests can run against an in-memory backend instead of the real keychain.
public struct KeychainItemStore: Sendable {
  public enum KeychainError: LocalizedError, Sendable {
    case commandFailed(status: Int32)
    case malformedPayload

    public var errorDescription: String? {
      switch self {
      case let .commandFailed(status): "The security command exited \(status)."
      case .malformedPayload: "The keychain payload could not be encoded."
      }
    }
  }

  private let readItem: @Sendable (String) throws -> Data?
  private let writeItem: @Sendable (Data, String) throws -> Void
  private let deleteItem: @Sendable (String) throws -> Void

  public init(
    account: String = NSUserName(),
    read: (@Sendable (String) throws -> Data?)? = nil,
    write: (@Sendable (Data, String) throws -> Void)? = nil,
    delete: (@Sendable (String) throws -> Void)? = nil
  ) {
    readItem = read ?? { service in try Self.securityRead(account: account, service: service) }
    writeItem = write ?? { data, service in try Self.securityWrite(data, account: account, service: service) }
    deleteItem = delete ?? { service in try Self.securityDelete(account: account, service: service) }
  }

  /// Returns the item bytes, `nil` when the item genuinely doesn't exist, and
  /// throws for any other failure (launch error, unexpected exit) so callers
  /// can fail closed instead of mistaking a transient failure for "empty".
  public func read(service: String) throws -> Data? {
    try readItem(service)
  }

  /// Best-effort read that maps every failure (including not-found) to `nil`.
  /// Only for callers where a missing value and a failed read are equivalent.
  public func readOptional(service: String) -> Data? {
    try? readItem(service)
  }

  public func write(_ data: Data, service: String) throws {
    try writeItem(data, service)
  }

  public func delete(service: String) throws {
    try deleteItem(service)
  }

  private static func securityRead(account: String, service: String) throws -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    // Exit 44 == "item not found": a real absence, not a failure. Every other
    // nonzero exit is a failure the caller must be able to fail closed on, and
    // a present-but-empty/undecodable item is NOT reported as absence (that
    // would let a corrupted index look like an empty registry) — it comes back
    // as bytes so the decoder rejects it.
    if process.terminationStatus == 44 {
      return nil
    }
    guard process.terminationStatus == 0 else {
      throw KeychainError.commandFailed(status: process.terminationStatus)
    }
    guard let text = String(data: output, encoding: .utf8) else {
      throw KeychainError.malformedPayload
    }
    return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
  }

  /// Writes (or updates, via `-U`) the item. The payload is fed over stdin
  /// with `security -i` so a bearer-token blob never appears in the process
  /// argument list.
  private static func securityWrite(_ data: Data, account: String, service: String) throws {
    guard let payload = String(data: data, encoding: .utf8) else {
      throw KeychainError.malformedPayload
    }
    let command = [
      "add-generic-password",
      "-U",
      "-a", quoted(account),
      "-s", quoted(service),
      "-w", quoted(payload),
    ].joined(separator: " ") + "\n"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["-i"]
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    stdin.fileHandleForWriting.write(Data(command.utf8))
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw KeychainError.commandFailed(status: process.terminationStatus)
    }
  }

  private static func securityDelete(account: String, service: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["delete-generic-password", "-a", account, "-s", service]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    // Exit 44 == "item not found"; treat deleting an absent item as success.
    guard process.terminationStatus == 0 || process.terminationStatus == 44 else {
      throw KeychainError.commandFailed(status: process.terminationStatus)
    }
  }

  /// Quotes a token for the `security -i` command parser: backslash-escaped
  /// backslashes and double quotes inside double quotes.
  static func quoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
