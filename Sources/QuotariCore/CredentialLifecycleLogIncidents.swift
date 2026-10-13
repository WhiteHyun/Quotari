import CryptoKit
import Foundation

extension CredentialLifecycleLogStore {
  /// Separate, bounded first-rejection snapshots survive normal-log compaction
  /// and process restarts. One incident per account + rejected refresh generation.
  var incidentsDirectory: URL {
    url.deletingLastPathComponent().appendingPathComponent("CredentialIncidents", isDirectory: true)
  }

  func preserveRejectionContext(_ event: CredentialLifecycleEvent) throws {
    guard event.kind == .refreshFailed, event.failure == .reauthenticationRequired else { return }
    try fileManager.createDirectory(at: incidentsDirectory, withIntermediateDirectories: true)
    try applyOwnerOnlyPermissions(to: incidentsDirectory, directory: true)
    try pruneIncidentFiles()
    let identity = [
      event.provider.rawValue,
      event.accountID ?? "unknown",
      event.diagnostic?.generation?.refresh ?? "legacy",
    ]
    .joined(separator: ":")
    let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    let target = incidentsDirectory.appendingPathComponent("\(name).jsonl")
    guard !fileManager.fileExists(atPath: target.path) else { return }
    // Preserve complete records only, including the rejection itself.
    let budget = min(maximumByteCount, 256 * 1024)
    let lines = try Data(contentsOf: url).split(separator: 0x0A)
    var selected: [Data] = []
    var count = 0
    for line in lines.reversed() {
      guard count + line.count + 1 <= budget else { break }
      selected.append(Data(line) + Data([0x0A]))
      count += line.count + 1
    }
    var snapshot = Data()
    for line in selected.reversed() {
      snapshot.append(line)
    }
    try snapshot.write(to: target, options: .atomic)
    try applyOwnerOnlyPermissions(to: target, directory: false)
    try pruneIncidentFiles()
  }

  func pruneIncidentFiles() throws {
    guard fileManager.fileExists(atPath: incidentsDirectory.path) else { return }
    let files = try fileManager.contentsOfDirectory(
      at: incidentsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
    ).filter { $0.pathExtension == "jsonl" }
    let dated = try files.map { file in
      try (file, file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
    }.sorted { $0.1 > $1.1 }
    let cutoff = now().addingTimeInterval(-retention)
    for (index, entry) in dated.enumerated() where index >= 8 || entry.1 < cutoff {
      try fileManager.removeItem(at: entry.0)
    }
  }
}
