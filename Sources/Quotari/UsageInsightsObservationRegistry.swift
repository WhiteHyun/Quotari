import CoreServices
import Foundation
import QuotariCore

struct UsageInsightsObservationKey: Hashable, Sendable {
  let provider: UsageProvider
  let credentialScopeID: String?
}

struct UsageInsightsLogObservation: Equatable, Sendable {
  let key: UsageInsightsObservationKey
  let roots: [URL]
}

protocol UsageInsightsChangeMonitoring: AnyObject, Sendable {
  func replaceObservations(
    _ observations: [UsageInsightsLogObservation],
    onChange: @escaping @Sendable (Set<UsageInsightsObservationKey>) -> Void
  )
  func stop()
}

final class DisabledUsageInsightsChangeMonitor: UsageInsightsChangeMonitoring, @unchecked Sendable {
  func replaceObservations(
    _: [UsageInsightsLogObservation],
    onChange _: @escaping @Sendable (Set<UsageInsightsObservationKey>) -> Void
  ) {}

  func stop() {}
}

struct UsageInsightsObservationRegistry: Equatable {
  private struct Entry: Equatable {
    let key: UsageInsightsObservationKey
    let rootPath: String
  }

  private let entries: [Entry]
  let watchPaths: [String]
  let allKeys: Set<UsageInsightsObservationKey>

  init(
    observations: [UsageInsightsLogObservation],
    fileManager: FileManager = .default,
    excludedAncestorPaths: Set<String>? = nil
  ) {
    var entries: [Entry] = []
    var watchPaths = Set<String>()
    var seenEntries = Set<String>()
    let excludedAncestorPaths = excludedAncestorPaths ?? [
      fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path,
      URL(fileURLWithPath: "/", isDirectory: true).path,
    ]

    for observation in observations {
      for root in observation.roots {
        let configuredURL = root.standardizedFileURL
        let routedPaths = Set([
          configuredURL.path,
          configuredURL.resolvingSymlinksInPath().path,
        ])
        for rootPath in routedPaths.sorted() {
          let identity = "\(observation.key.provider.rawValue)\u{0}\(observation.key.credentialScopeID ?? "")\u{0}\(rootPath)"
          guard seenEntries.insert(identity).inserted else { continue }
          entries.append(Entry(key: observation.key, rootPath: rootPath))
          let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
          if Self.isExistingDirectory(rootURL, fileManager: fileManager) {
            watchPaths.insert(rootPath)
            continue
          }
          let parent = rootURL.deletingLastPathComponent()
          if !excludedAncestorPaths.contains(parent.path),
             Self.isExistingDirectory(parent, fileManager: fileManager) {
            watchPaths.insert(parent.path)
          }
        }
      }
    }

    self.entries = entries
    self.watchPaths = watchPaths.sorted()
    allKeys = Set(entries.map(\.key))
  }

  func affectedKeys(path: String, flags: FSEventStreamEventFlags) -> Set<UsageInsightsObservationKey> {
    let droppedFlags = kFSEventStreamEventFlagMustScanSubDirs
      | kFSEventStreamEventFlagUserDropped
      | kFSEventStreamEventFlagKernelDropped
    if flags & FSEventStreamEventFlags(droppedFlags) != 0 {
      return Set(entries.map(\.key))
    }
    let path = URL(fileURLWithPath: path).standardizedFileURL.path
    guard Self.isRelevant(path: path, flags: flags) else { return [] }
    return Set(entries.compactMap { entry in
      Self.pathsOverlap(path, entry.rootPath) ? entry.key : nil
    })
  }

  private static func isRelevant(path: String, flags: FSEventStreamEventFlags) -> Bool {
    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
      return true
    }
    if flags == 0 || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
      return true
    }
    let mutationFlags = kFSEventStreamEventFlagItemCreated
      | kFSEventStreamEventFlagItemRemoved
      | kFSEventStreamEventFlagItemRenamed
      | kFSEventStreamEventFlagItemModified
    return path.lowercased().hasSuffix(".jsonl")
      && flags & FSEventStreamEventFlags(mutationFlags) != 0
  }

  private static func pathsOverlap(_ eventPath: String, _ rootPath: String) -> Bool {
    eventPath == rootPath
      || eventPath.hasPrefix(rootPath + "/")
      || rootPath.hasPrefix(eventPath + "/")
  }

  private static func isExistingDirectory(
    _ url: URL,
    fileManager: FileManager
  ) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
