import Foundation
import LocalAuthentication
import Security

struct KeychainSecurityOperations: @unchecked Sendable {
  var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  var update: (CFDictionary, CFDictionary) -> OSStatus
  var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  var delete: (CFDictionary) -> OSStatus

  static let live = Self(
    copyMatching: SecItemCopyMatching,
    update: SecItemUpdate,
    add: SecItemAdd,
    delete: SecItemDelete
  )
}

struct SecurityFrameworkKeychainStore: Sendable {
  private let operations: KeychainSecurityOperations

  init(operations: KeychainSecurityOperations = .live) {
    self.operations = operations
  }

  func read(account: String?, service: String) throws -> Data? {
    var query = itemQuery(account: account, service: service)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = operations.copyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainItemStore.KeychainError.commandFailed(status: status)
    }
    guard let data = result as? Data else {
      throw KeychainItemStore.KeychainError.malformedPayload
    }
    return data
  }

  func write(_ data: Data, account: String, service: String) throws {
    let query = itemQuery(account: account, service: service)
    let values: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = operations.update(
      query as CFDictionary,
      values as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainItemStore.KeychainError.commandFailed(status: updateStatus)
    }

    var addQuery = query
    for (key, value) in values {
      addQuery[key] = value
    }
    let addStatus = operations.add(addQuery as CFDictionary, nil)
    if addStatus == errSecSuccess {
      return
    }
    if addStatus == errSecDuplicateItem {
      let retryStatus = operations.update(
        query as CFDictionary,
        values as CFDictionary
      )
      guard retryStatus == errSecSuccess else {
        throw KeychainItemStore.KeychainError.commandFailed(status: retryStatus)
      }
      return
    }
    throw KeychainItemStore.KeychainError.commandFailed(status: addStatus)
  }

  func delete(account: String, service: String) throws {
    let status = operations.delete(
      itemQuery(account: account, service: service) as CFDictionary
    )
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainItemStore.KeychainError.commandFailed(status: status)
    }
  }

  private func itemQuery(account: String?, service: String) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseAuthenticationContext as String: context,
    ]
    if let account {
      query[kSecAttrAccount as String] = account
    }
    return query
  }
}
