import Foundation

public struct CLIActivityDetector: Sendable {
  enum DetectionError: LocalizedError {
    case commandFailed(status: Int32)
    case malformedOutput

    var errorDescription: String? {
      switch self {
      case let .commandFailed(status):
        "Inspecting running CLI processes failed (ps exited \(status))."
      case .malformedOutput:
        "The running process list could not be decoded."
      }
    }
  }

  private let processList: @Sendable () throws -> String

  public init() {
    processList = Self.loadProcessList
  }

  init(processList: @escaping @Sendable () throws -> String) {
    self.processList = processList
  }

  /// Returns exact executable-name matches only. This intentionally avoids
  /// substring matching (`CodexBar`, paths containing "claude", and similar
  /// false positives), while still finding script-launched Claude processes
  /// because macOS reports their process name as `claude`.
  public func activeProcesses(for provider: UsageProvider) throws -> [String] {
    let expectedName = switch provider {
    case .claude: "claude"
    case .codex: "codex"
    }
    return try processList()
      .split(separator: "\n")
      .compactMap { line -> (pid: Int, executable: String)? in
        let fields = line.split(
          maxSplits: 1,
          whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard fields.count == 2, let pid = Int(fields[0]) else { return nil }
        return (pid, String(fields[1]).trimmingCharacters(in: .whitespaces))
      }
      .filter { URL(fileURLWithPath: $0.executable).lastPathComponent.lowercased() == expectedName }
      .map { "\(expectedName) (PID \($0.pid))" }
  }

  private static func loadProcessList() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ww", "-axo", "pid=,comm="]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw DetectionError.commandFailed(status: process.terminationStatus)
    }
    guard let text = String(data: output, encoding: .utf8) else {
      throw DetectionError.malformedOutput
    }
    return text
  }
}
