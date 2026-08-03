import Foundation
@testable import QuotariCore
import Testing

final class CodexKeychainSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Data?
  private var readCount = 0
  private var replacement: (read: Int, payload: Data)?
  private var afterWrite: (@Sendable () throws -> Void)?
  var failsReads = false
  var failsReadsAfterWrite = false
  var failsWrites = false
  private(set) var writeCount = 0

  init(_ value: Data? = nil) {
    storage = value
  }

  func read(service _: String, account _: String) throws -> Data? {
    try lock.withLock {
      if failsReads || (failsReadsAfterWrite && writeCount > 0) {
        throw KeychainItemStore.KeychainError.commandFailed(status: 36)
      }
      readCount += 1
      if replacement?.read == readCount {
        storage = replacement?.payload
      }
      return storage
    }
  }

  func replace(onRead read: Int, with payload: Data) {
    lock.withLock { replacement = (read, payload) }
  }

  func runAfterNextWrite(_ action: @escaping @Sendable () throws -> Void) {
    lock.withLock { afterWrite = action }
  }

  func write(_ data: Data, service _: String, account _: String) throws {
    let action = try lock.withLock {
      writeCount += 1
      if failsWrites {
        throw KeychainItemStore.KeychainError.commandFailed(status: 37)
      }
      storage = data
      defer { afterWrite = nil }
      return afterWrite
    }
    try action?()
  }

  func delete(service _: String, account _: String) {
    lock.withLock { storage = nil }
  }

  var value: Data? {
    lock.withLock { storage }
  }
}

struct CodexAuthStorageTests {
  @Test func parsesTopLevelCredentialModeWithoutReadingProfileOverrides() throws {
    let contents = #"""
    # global selection
    cli_auth_credentials_store = "auto" # prefer Keychain

    [profiles.file-only]
    cli_auth_credentials_store = "file"
    """#

    #expect(try CodexAuthStorage.parseMode(contents) == .auto)
    #expect(try CodexAuthStorage.parseMode("model = \"gpt-5.6\"") == .file)
    #expect(throws: CodexAuthStorageError.self) {
      _ = try CodexAuthStorage.parseMode("cli_auth_credentials_store = \"ephemeral\"")
    }
  }

  @Test func encryptedKeyringConfigurationFailsClosed() throws {
    let home = try switchTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"""
    cli_auth_credentials_store = "keyring"
    [features]
    secret_auth_storage = true
    """#.utf8).write(to: directory.appendingPathComponent("config.toml"))
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: { _, _ in nil })

    #expect(throws: CodexAuthStorageError.self) {
      _ = try storage.snapshot()
    }
  }

  @Test func dottedAndInlineEncryptedKeyringConfigurationsFailClosed() throws {
    let configurations = [
      "cli_auth_credentials_store = \"keyring\"\nfeatures.secret_auth_storage = true\n",
      "cli_auth_credentials_store = \"auto\"\nfeatures = { secret_auth_storage = true }\n",
    ]

    for configuration in configurations {
      let home = try switchTemporaryHome()
      defer { try? FileManager.default.removeItem(at: home) }
      let directory = home.appendingPathComponent(".codex")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(configuration.utf8).write(to: directory.appendingPathComponent("config.toml"))
      let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: { _, _ in nil })

      #expect(throws: CodexAuthStorageError.self) {
        _ = try storage.snapshot()
      }
    }
  }

  @Test func keyringModeDiscoversCapturesAndSwitchesTheActualCodexSlot() async throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = CodexKeychainSlot(codexPayload(account: "acct-live", token: "live-tok", refresh: "live-ref"))
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: slot.read)

    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: home,
      keychainData: { nil },
      codexKeychainData: { service, account in try? slot.read(service: service, account: account) },
      capturedAccounts: registry
    )
    let accounts = await discovery.accounts(for: .codex)
    let live = try #require(accounts.first)
    #expect(live.credentialSource == storage.keychainSource)
    #expect(live.detail == "Keychain")

    let capture = AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in nil },
      codexKeychainRead: { service, account in try? slot.read(service: service, account: account) }
    )
    let captured = try capture.capture(live, now: Date(timeIntervalSince1970: 100))
    #expect(captured.origin == storage.keychainSource)

    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)
    let written = try switcher.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 200)
    )

    #expect(written.credentialSource == storage.keychainSource)
    #expect(try CodexCredentialsStore.parse(#require(slot.value)).accountID == "acct-saved")
    #expect(registry.load().contains { $0.id == "codex:acct-live" })
    #expect(!FileManager.default.fileExists(atPath: storage.authFileURL.path))
  }
}

extension CodexAuthStorageTests {
  @Test func autoModeRefusesToSwitchWhenTheKeyringIsUnreadable() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "auto")
    defer { try? FileManager.default.removeItem(at: home) }
    let authURL = home.appendingPathComponent(".codex/auth.json")
    let original = codexPayload(account: "acct-live", token: "live-tok", refresh: "live-ref")
    try writeSecure(original, to: authURL)
    let slot = CodexKeychainSlot()
    slot.failsReads = true
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    #expect(throws: AccountSwitchError.self) {
      _ = try switcher.switchCLI(
        toRegistryAccount: saved.id,
        now: Date(timeIntervalSince1970: 200)
      )
    }

    #expect(try Data(contentsOf: authURL) == original)
    #expect(slot.writeCount == 0)
    #expect(registry.load().contains { $0.id == "codex:acct-live" })
  }

  @Test func autoModeKeepsTheFileFallbackWhenTheKeyringIsGenuinelyEmpty() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "auto")
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = CodexKeychainSlot()
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: slot.read)
    try writeSecure(
      codexPayload(account: "acct-live", token: "live-tok", refresh: "live-ref"),
      to: storage.authFileURL
    )
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    let written = try switcher.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 200)
    )

    #expect(written.credentialSource == .codexAuthFile(path: storage.authFileURL.path))
    #expect(try CodexCredentialsStore.load(url: storage.authFileURL).accountID == "acct-saved")
    #expect(slot.value == nil)
    #expect(slot.writeCount == 0)
    #expect(registry.load().contains { $0.id == "codex:acct-live" })
  }

  @Test func autoModeDoesNotTryToCreateAnEmptyKeyringItem() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "auto")
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = CodexKeychainSlot()
    slot.failsWrites = true
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: slot.read)
    try writeSecure(
      codexPayload(account: "acct-live", token: "live-tok", refresh: "live-ref"),
      to: storage.authFileURL
    )
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    let written = try switcher.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 200)
    )

    #expect(written.credentialSource == .codexAuthFile(path: storage.authFileURL.path))
    #expect(try CodexCredentialsStore.load(url: storage.authFileURL).accountID == "acct-saved")
    #expect(slot.value == nil)
    #expect(slot.writeCount == 0)
  }

  @Test func keyringModeFailsClosedWhenCodexHasNotCreatedTheItem() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = CodexKeychainSlot()
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    var thrown: AccountSwitchError?
    do {
      _ = try switcher.switchCLI(
        toRegistryAccount: saved.id,
        now: Date(timeIntervalSince1970: 200)
      )
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .writeFailed = thrown else {
      Issue.record("expected .writeFailed, got \(String(describing: thrown))")
      return
    }
    #expect(slot.writeCount == 0)
  }

  @Test func keyringWriteFailureLeavesThePreviousLoginUntouched() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let original = codexPayload(account: "acct-live", token: "live-tok", refresh: "live-ref")
    let slot = CodexKeychainSlot(original)
    slot.failsWrites = true
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    #expect(throws: AccountSwitchError.self) {
      try switcher.switchCLI(toRegistryAccount: saved.id, now: Date(timeIntervalSince1970: 200))
    }
    #expect(slot.value == original)
    #expect(registry.load().contains { $0.id == "codex:acct-live" })
  }

  @Test func unverifiableKeyringWriteFailureReportsAPartialSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let original = codexPayload(account: "acct-live", token: "live-tok", refresh: "live-ref")
    let slot = CodexKeychainSlot(original)
    slot.failsWrites = true
    slot.failsReadsAfterWrite = true
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    var thrown: AccountSwitchError?
    do {
      _ = try switcher.switchCLI(
        toRegistryAccount: saved.id,
        now: Date(timeIntervalSince1970: 200)
      )
    } catch let error as AccountSwitchError {
      thrown = error
    }

    guard case .partialSwitch = thrown else {
      Issue.record("expected .partialSwitch, got \(String(describing: thrown))")
      return
    }
  }

  @Test func changedFallbackFileIsPreservedAndTheKeyringIsRolledBack() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "keyring")
    defer { try? FileManager.default.removeItem(at: home) }
    let keyringOriginal = codexPayload(account: "acct-keyring", token: "key-tok", refresh: "key-ref")
    let fileOriginal = codexPayload(account: "acct-file-before", token: "old-tok", refresh: "old-ref")
    let fileReplacement = codexPayload(account: "acct-file-after", token: "new-tok", refresh: "new-ref")
    let slot = CodexKeychainSlot(keyringOriginal)
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: slot.read)
    try writeSecure(fileOriginal, to: storage.authFileURL)
    slot.runAfterNextWrite {
      try writeSecure(fileReplacement, to: storage.authFileURL)
    }
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    #expect(throws: AccountSwitchError.self) {
      _ = try switcher.switchCLI(
        toRegistryAccount: saved.id,
        now: Date(timeIntervalSince1970: 200)
      )
    }

    #expect(slot.value == keyringOriginal)
    #expect(try Data(contentsOf: storage.authFileURL) == fileReplacement)
    let ids = Set(registry.load().map(\.id))
    #expect(ids.contains("codex:acct-keyring"))
    #expect(ids.contains("codex:acct-file-before"))
    #expect(ids.contains("codex:acct-file-after"))
  }

  @Test func autoModeBacksUpAKeyringLoginThatAppearsDuringTheSwitch() throws {
    let registry = makeSwitchRegistry()
    let saved = try savedCodexAccount(registry: registry)
    let home = try codexHome(mode: "auto")
    defer { try? FileManager.default.removeItem(at: home) }
    let slot = CodexKeychainSlot()
    let storage = CodexAuthStorage(environment: [:], home: home, keychainRead: slot.read)
    try writeSecure(
      codexPayload(account: "acct-file", token: "file-tok", refresh: "file-ref"),
      to: storage.authFileURL
    )
    slot.replace(
      onRead: 2,
      with: codexPayload(account: "acct-keyring", token: "keyring-tok", refresh: "keyring-ref")
    )
    let switcher = makeCodexSwitcher(registry: registry, home: home, slot: slot)

    let written = try switcher.switchCLI(
      toRegistryAccount: saved.id,
      now: Date(timeIntervalSince1970: 200)
    )

    #expect(written.credentialSource == storage.keychainSource)
    #expect(try CodexCredentialsStore.parse(#require(slot.value)).accountID == "acct-saved")
    let ids = Set(registry.load().map(\.id))
    #expect(ids.contains("codex:acct-file"))
    #expect(ids.contains("codex:acct-keyring"))
  }
}

extension CodexAuthStorageTests {
  func codexHome(mode: String) throws -> URL {
    let home = try switchTemporaryHome()
    let directory = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("cli_auth_credentials_store = \"\(mode)\"\n".utf8)
      .write(to: directory.appendingPathComponent("config.toml"))
    return home
  }

  func writeSecure(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func makeCodexSwitcher(
    registry: CapturedAccountStore,
    home: URL,
    slot: CodexKeychainSlot
  ) -> AccountSwitchService {
    AccountSwitchService(
      capturedAccounts: registry,
      environment: [:],
      home: home,
      keychainRead: { _ in nil },
      keychainWrite: { _, _ in },
      codexKeychainRead: slot.read,
      codexKeychainWrite: slot.write,
      codexKeychainDelete: { service, account in slot.delete(service: service, account: account) }
    )
  }
}
