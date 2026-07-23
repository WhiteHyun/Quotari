import Foundation

final class LocalUsageScopeIdentityStore: @unchecked Sendable {
  private static let coordinationLock = NSLock()

  private let lock = NSLock()
  private let cacheDirectory: URL
  private let fileManager: FileManager
  private let mutationHook: (@Sendable () -> Void)?
  private var cachedMappings: [String: String]?

  init(
    cacheDirectory: URL,
    fileManager: FileManager = .default,
    mutationHook: (@Sendable () -> Void)? = nil
  ) {
    self.cacheDirectory = cacheDirectory
    self.fileManager = fileManager
    self.mutationHook = mutationHook
  }

  func identities(for roots: [URL]) -> [String] {
    Self.coordinationLock.withLock {
      lock.withLock {
        var mappings = cachedMappings ?? [:]
        let identities = roots.map { root in
          let rawPath = root.standardizedFileURL.path
          let rawIdentity = fingerprint(rawPath)
          let resolvedPath = resolvingExistingAncestors(of: root).path
          guard resolvedPath != rawPath || fileManager.fileExists(atPath: root.path) else {
            let identity = loadMapping(for: rawIdentity)
              ?? mappings[rawIdentity]
              ?? rawIdentity
            mappings[rawIdentity] = identity
            return identity
          }
          let resolvedIdentity = fingerprint(resolvedPath)
          if mappings[rawIdentity] != resolvedIdentity {
            mutationHook?()
            mappings[rawIdentity] = resolvedIdentity
            saveMapping(resolvedIdentity, for: rawIdentity)
          }
          return resolvedIdentity
        }
        cachedMappings = mappings
        return Array(Set(identities)).sorted()
      }
    }
  }

  private func loadMapping(for aliasIdentity: String) -> String? {
    guard let data = try? Data(contentsOf: mappingURL(for: aliasIdentity)),
          let value = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return value
  }

  private func saveMapping(_ resolvedIdentity: String, for aliasIdentity: String) {
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    try? Data(resolvedIdentity.utf8)
      .write(to: mappingURL(for: aliasIdentity), options: [.atomic])
  }

  private func mappingURL(for aliasIdentity: String) -> URL {
    cacheDirectory.appendingPathComponent(
      "scope-root-identity-v1-\(aliasIdentity).txt"
    )
  }

  private func resolvingExistingAncestors(of url: URL) -> URL {
    var ancestor = url.standardizedFileURL
    var missingComponents: [String] = []
    while !fileManager.fileExists(atPath: ancestor.path),
          ancestor.path != "/" {
      missingComponents.append(ancestor.lastPathComponent)
      ancestor.deleteLastPathComponent()
    }
    var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
    for component in missingComponents.reversed() {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }

  private func fingerprint(_ value: String) -> String {
    ProviderCredentialIdentity.fingerprint(of: value)
  }
}
