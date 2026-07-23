import Foundation

struct LocalUsageCacheMutationKey: Hashable, Sendable {
  let scopeKey: UsageInsightsScopeKey
  let historyDays: Int
}

struct LocalUsageCacheMutationToken: Sendable {
  let key: LocalUsageCacheMutationKey
  let generation: UInt64
}

final class LocalUsageCacheCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var generations: [LocalUsageCacheMutationKey: UInt64] = [:]

  func begin(key: LocalUsageCacheMutationKey) -> LocalUsageCacheMutationToken {
    lock.withLock {
      let generation = generations[key, default: 0] &+ 1
      generations[key] = generation
      return LocalUsageCacheMutationToken(key: key, generation: generation)
    }
  }

  func read<Value>(
    key: LocalUsageCacheMutationKey,
    operation: () -> Value
  ) -> Value {
    lock.withLock(operation)
  }

  @discardableResult
  func performIfCurrent(
    _ token: LocalUsageCacheMutationToken,
    operation: () -> Void
  ) -> Bool {
    lock.withLock {
      guard generations[token.key] == token.generation else { return false }
      operation()
      return true
    }
  }

  func invalidate(
    key: LocalUsageCacheMutationKey,
    operation: () -> Void
  ) {
    lock.withLock {
      generations[key, default: 0] &+= 1
      operation()
    }
  }
}
