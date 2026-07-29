import Foundation

/// Reads and writes generic-password keychain items. Provider-owned credential
/// slots keep using the stable `/usr/bin/security` binary so their ACL consent
/// does not follow each rebuilt development binary. Quotari-owned items use
/// ``appOwned(account:)`` instead, which passes arbitrary-sized payloads to
/// Security.framework as `Data` without the line-oriented `security -i` parser.
/// Operations remain injectable for deterministic tests.
public struct KeychainItemStore: Sendable {
  public enum KeychainError: LocalizedError, Sendable {
    case commandFailed(status: Int32)
    case malformedPayload

    public var errorDescription: String? {
      switch self {
      case let .commandFailed(status): "The Keychain operation failed (\(status))."
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

  /// A direct Security.framework backend for items owned by Quotari. Unlike
  /// `security -i`, it does not impose a command-line parser limit on payloads.
  public static func appOwned(account: String = NSUserName()) -> Self {
    let keychain = SecurityFrameworkKeychainStore()
    return Self(
      account: account,
      read: { service in try keychain.read(account: account, service: service) },
      write: { data, service in try keychain.write(data, account: account, service: service) },
      delete: { service in try keychain.delete(account: account, service: service) }
    )
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

  /// Reads a generic-password item by *service only* (no account filter),
  /// matching how Claude Code's credential item is discovered — but throwing
  /// so callers can fail closed. `nil` only for a genuine not-found (exit 44).
  public static func readByService(_ service: String) throws -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus == 44 {
      return nil
    }
    guard process.terminationStatus == 0 else {
      throw KeychainError.commandFailed(status: process.terminationStatus)
    }
    guard let text = String(data: output, encoding: .utf8) else {
      throw KeychainError.malformedPayload
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : Data(trimmed.utf8)
  }

  /// Writes an item identified by *service*, reusing the existing item's
  /// account attribute so it updates the same item the service-only read
  /// found (a generic-password item is keyed by service AND account; writing
  /// under a different account would create a second, ambiguous item). Falls
  /// back to the current user when no item exists yet.
  public static func writeByService(_ data: Data, service: String) throws {
    // Determine the existing item's account so we update it in place. A found
    // item with an unreadable account attribute fails closed — writing under
    // NSUserName() would create a second, ambiguous item; only a genuine
    // absence (nil) falls back to the current user (creating the item).
    let account = try accountForService(service) ?? NSUserName()
    try securityWrite(data, account: account, service: service)
  }

  /// Deletes the item identified by *service*, resolving the same account
  /// attribute used by ``writeByService(_:service:)``. A genuinely absent
  /// item is already in the requested state.
  public static func deleteByService(_ service: String) throws {
    guard let account = try accountForService(service) else { return }
    try securityDelete(account: account, service: service)
  }

  public func write(_ data: Data, service: String) throws {
    try writeItem(data, service)
  }

  public func delete(service: String) throws {
    try deleteItem(service)
  }

  /// The `acct` attribute of the item for `service`, read without printing
  /// the secret (`security find-generic-password` without `-g`/`-w`). Nil
  /// only when no item exists (exit 44); throws on a command failure or an
  /// item whose account can't be parsed, so callers can fail closed.
  private static func accountForService(_ service: String) throws -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus == 44 {
      return nil
    }
    guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else {
      throw KeychainError.commandFailed(status: process.terminationStatus)
    }
    // Attribute line: `    "acct"<blob>="value"`
    for line in text.split(separator: "\n") where line.contains("\"acct\"") {
      guard let eq = line.range(of: "=\"") else { continue }
      let rest = line[eq.upperBound...]
      if let close = rest.range(of: "\""), !rest[..<close.lowerBound].isEmpty {
        return String(rest[..<close.lowerBound])
      }
    }
    // The item exists but its account attribute couldn't be parsed — fail
    // closed rather than fall back to a different account.
    throw KeychainError.malformedPayload
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
