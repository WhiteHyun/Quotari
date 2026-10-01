import Foundation
@testable import QuotariCore
import Security
import Testing

struct LiveKeychainAccessTests {
  @Test func thisTestProcessNeverReachesTheLiveKeychain() {
    #expect(!LiveKeychainAccess.isAllowed)
    #expect(KeychainItemStore().readOptional(service: "Quotari-Captured-Accounts-Index") == nil)
    #expect(throws: KeychainItemStore.KeychainError.self) {
      try KeychainItemStore.appOwned().write(Data("x".utf8), service: "Quotari-LiveKeychainAccessTests")
    }
  }

  @Test(arguments: ["xctest", "swiftpm-testing-helper", "QuotariPackageTests"])
  func runnerProcessesAreRefused(processName: String) {
    #expect(!LiveKeychainAccess.isAllowed(processName: processName, environment: [:]))
  }

  @Test func xcodeTestEnvironmentIsRefused() {
    #expect(!LiveKeychainAccess.isAllowed(
      processName: "Quotari",
      environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"]
    ))
  }

  @Test func theAppProcessIsAllowed() {
    #expect(LiveKeychainAccess.isAllowed(processName: "Quotari", environment: [:]))
  }

  @Test func liveE2EOptInIsAllowedFromATestRunner() {
    #expect(LiveKeychainAccess.isAllowed(
      processName: "swiftpm-testing-helper",
      environment: ["QUOTARI_RUN_CLAUDE_SWITCH_E2E": "1"]
    ))
  }

  @Test func refusedOperationsBehaveLikeAnEmptyKeychainThatRejectsWrites() throws {
    let store = SecurityFrameworkKeychainStore(operations: .refused)

    #expect(try store.read(account: "account", service: "service") == nil)
    try store.delete(account: "account", service: "service")
    #expect(throws: KeychainItemStore.KeychainError.self) {
      try store.write(Data("x".utf8), account: "account", service: "service")
    }
  }
}
