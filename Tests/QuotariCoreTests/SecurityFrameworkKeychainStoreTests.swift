import Foundation
@testable import QuotariCore
import Security
import Testing

struct SecurityFrameworkKeychainStoreTests {
  @Test func largePayloadIsPassedToSecurityFrameworkAsRawData() throws {
    let recorder = KeychainSecurityRecorder(
      updateStatuses: [errSecItemNotFound],
      addStatus: errSecSuccess
    )
    let store = SecurityFrameworkKeychainStore(operations: recorder.operations)
    let payload = Data((0 ..< 8192).map { UInt8($0 % 251) })

    try store.write(payload, account: "account", service: "service")

    #expect(recorder.addedData == payload)
    #expect(recorder.addedAccessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
  }

  @Test func existingItemUpdateMigratesAccessibility() throws {
    let recorder = KeychainSecurityRecorder(
      updateStatuses: [errSecSuccess],
      addStatus: errSecSuccess
    )
    let store = SecurityFrameworkKeychainStore(operations: recorder.operations)
    let payload = Data("updated".utf8)

    try store.write(payload, account: "account", service: "service")

    #expect(recorder.updatedData == payload)
    #expect(recorder.updatedAccessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect(recorder.addCallCount == 0)
  }

  @Test func duplicateAddRaceRetriesTheUpdate() throws {
    let recorder = KeychainSecurityRecorder(
      updateStatuses: [errSecItemNotFound, errSecSuccess],
      addStatus: errSecDuplicateItem
    )
    let store = SecurityFrameworkKeychainStore(operations: recorder.operations)

    try store.write(Data("payload".utf8), account: "account", service: "service")

    #expect(recorder.updateCallCount == 2)
    #expect(recorder.addCallCount == 1)
  }

  @Test func readReturnsBinaryPayloadWithoutStringNormalization() throws {
    let payload = Data([0x00, 0x20, 0x0A, 0xFF])
    let recorder = KeychainSecurityRecorder(
      copyStatus: errSecSuccess,
      copyResult: payload as CFData
    )
    let store = SecurityFrameworkKeychainStore(operations: recorder.operations)

    let loaded = try store.read(account: "account", service: "service")

    #expect(loaded == payload)
  }

  @Test func missingReadAndDeleteAreIdempotent() throws {
    let recorder = KeychainSecurityRecorder(
      copyStatus: errSecItemNotFound,
      deleteStatus: errSecItemNotFound
    )
    let store = SecurityFrameworkKeychainStore(operations: recorder.operations)

    #expect(try store.read(account: "account", service: "service") == nil)
    try store.delete(account: "account", service: "service")
  }
}

private final class KeychainSecurityRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var updateStatuses: [OSStatus]
  private let addStatus: OSStatus
  private let copyStatus: OSStatus
  private let copyResult: CFTypeRef?
  private let deleteStatus: OSStatus
  private var addedAttributes: [String: Any] = [:]
  private var updatedAttributes: [String: Any] = [:]
  private var updateCalls = 0
  private var addCalls = 0

  init(
    updateStatuses: [OSStatus] = [],
    addStatus: OSStatus = errSecSuccess,
    copyStatus: OSStatus = errSecItemNotFound,
    copyResult: CFTypeRef? = nil,
    deleteStatus: OSStatus = errSecSuccess
  ) {
    self.updateStatuses = updateStatuses
    self.addStatus = addStatus
    self.copyStatus = copyStatus
    self.copyResult = copyResult
    self.deleteStatus = deleteStatus
  }

  var operations: KeychainSecurityOperations {
    KeychainSecurityOperations(
      copyMatching: { _, result in
        if let copyResult = self.copyResult {
          result?.pointee = copyResult
        }
        return self.copyStatus
      },
      update: { _, attributes in
        self.lock.withLock {
          self.updateCalls += 1
          self.updatedAttributes = attributes as? [String: Any] ?? [:]
          return self.updateStatuses.isEmpty
            ? errSecParam
            : self.updateStatuses.removeFirst()
        }
      },
      add: { attributes, _ in
        self.lock.withLock {
          self.addCalls += 1
          self.addedAttributes = attributes as? [String: Any] ?? [:]
        }
        return self.addStatus
      },
      delete: { _ in self.deleteStatus }
    )
  }

  var addedData: Data? {
    lock.withLock { addedAttributes[kSecValueData as String] as? Data }
  }

  var addedAccessibility: String? {
    lock.withLock { addedAttributes[kSecAttrAccessible as String] as? String }
  }

  var updatedData: Data? {
    lock.withLock { updatedAttributes[kSecValueData as String] as? Data }
  }

  var updatedAccessibility: String? {
    lock.withLock { updatedAttributes[kSecAttrAccessible as String] as? String }
  }

  var updateCallCount: Int {
    lock.withLock { updateCalls }
  }

  var addCallCount: Int {
    lock.withLock { addCalls }
  }
}
