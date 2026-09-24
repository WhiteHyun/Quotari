import Foundation
import Security

/// Test runners are unsigned helpers outside every Quotari item's ACL and
/// partition list, so each live keychain touch from a test raises a consent
/// prompt (and "Always Allow" permanently widens the item's ACL). Live access
/// from a test process is therefore refused unless a live E2E run opts in.
enum LiveKeychainAccess {
  static let isAllowed = isAllowed(
    processName: ProcessInfo.processInfo.processName,
    environment: ProcessInfo.processInfo.environment
  )

  static func isAllowed(processName: String, environment: [String: String]) -> Bool {
    if environment["QUOTARI_RUN_CLAUDE_SWITCH_E2E"] == "1" {
      return true
    }
    return !isTestProcess(processName: processName, environment: environment)
  }

  static func isTestProcess(processName: String, environment: [String: String]) -> Bool {
    let testRunnerNames: Set = ["xctest", "swiftpm-testing-helper"]
    if testRunnerNames.contains(processName) || processName.hasSuffix("PackageTests") {
      return true
    }
    return environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
      || environment["XCTestBundlePath"] != nil
  }

  /// Status reported to Security.framework callers when live access is refused.
  static let refusedStatus = errSecInteractionNotAllowed
}
