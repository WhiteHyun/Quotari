import Foundation

enum ClaudeDesktopProjectRoots {
  /// Every log-change event resolves scope roots on the main actor and again
  /// in the background scan; the walk below is a bounded directory crawl, so
  /// its result is shared for a short window instead of repeated per call.
  /// New desktop sessions therefore appear within `cacheLifetime`.
  static let cacheLifetime: TimeInterval = 30
  private static let cache = LocatedRootsCache()

  static func locate(
    homeDirectory: URL,
    fileManager: FileManager = .default,
    now: Date = Date()
  ) -> [URL] {
    guard fileManager === FileManager.default else {
      return uncachedLocate(homeDirectory: homeDirectory, fileManager: fileManager)
    }
    return cache.roots(
      for: homeDirectory.standardizedFileURL.path,
      now: now,
      lifetime: cacheLifetime
    ) {
      uncachedLocate(homeDirectory: homeDirectory, fileManager: fileManager)
    }
  }

  static func uncachedLocate(homeDirectory: URL, fileManager: FileManager) -> [URL] {
    var roots: [URL] = []
    var queue = sessionRoots(homeDirectory: homeDirectory)
      .map { (url: $0.standardizedFileURL, depth: 0) }
    var visited = Set(queue.map(\.url.path))
    var index = 0
    let maxDepth = 4

    while index < queue.count {
      let current = queue[index]
      index += 1
      if let projects = projectsRoot(under: current.url, fileManager: fileManager) {
        roots.append(projects)
      }
      guard current.depth < maxDepth else { continue }
      for child in childDirectories(at: current.url, fileManager: fileManager) {
        let standardized = child.standardizedFileURL
        guard visited.insert(standardized.path).inserted else { continue }
        queue.append((standardized, current.depth + 1))
      }
    }
    return roots
  }

  static func sessionRoots(homeDirectory: URL) -> [URL] {
    let applicationSupport = homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("Claude", isDirectory: true)
    return [
      "local-agent-mode-sessions",
      "claude-code-sessions",
    ].map { applicationSupport.appendingPathComponent($0, isDirectory: true) }
  }

  private static func projectsRoot(under base: URL, fileManager: FileManager) -> URL? {
    let projects = base
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: projects.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else { return nil }
    return projects
  }

  private static func childDirectories(at url: URL, fileManager: FileManager) -> [URL] {
    let skippedNames: Set = [
      ".build",
      ".git",
      "build",
      "DerivedData",
      "node_modules",
      "outputs",
      "target",
    ]
    guard let children = try? fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }

    return children.compactMap { child in
      guard !skippedNames.contains(child.lastPathComponent),
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isSymbolicLink != true,
            values.isDirectory == true
      else { return nil }
      return child
    }
  }
}

private final class LocatedRootsCache: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String: (roots: [URL], locatedAt: Date)] = [:]

  func roots(
    for home: String,
    now: Date,
    lifetime: TimeInterval,
    locate: () -> [URL]
  ) -> [URL] {
    if let entry = lock.withLock({ entries[home] }),
       now >= entry.locatedAt,
       now.timeIntervalSince(entry.locatedAt) < lifetime {
      return entry.roots
    }
    let roots = locate()
    lock.withLock { entries[home] = (roots, now) }
    return roots
  }
}
