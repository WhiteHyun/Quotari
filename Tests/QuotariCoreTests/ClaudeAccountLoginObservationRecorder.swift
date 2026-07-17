import Foundation
@testable import QuotariCore

final class ClaudeLoginObservationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ClaudeLoginCredentialObservation] = []

  var values: [ClaudeLoginCredentialObservation] {
    lock.withLock { storage }
  }

  func append(_ value: ClaudeLoginCredentialObservation) {
    lock.withLock { storage.append(value) }
  }
}
