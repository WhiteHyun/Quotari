import Foundation

public struct CLIActivityDetector: Sendable {
  static let processArguments = ["-ww", "-x", "-o", "pid=,args="]

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

  /// Returns exact executable or interpreter-script name matches. Inspecting
  /// the command arguments is required for npm/shebang installations, whose
  /// executable image is an interpreter such as `node` or `bash`.
  public func activeProcesses(for provider: UsageProvider) throws -> [String] {
    let expectedName = switch provider {
    case .claude: "claude"
    case .codex: "codex"
    }
    return try processList()
      .split(separator: "\n")
      .compactMap { line -> (pid: Int, command: String)? in
        let fields = line.split(
          maxSplits: 1,
          whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard fields.count == 2, let pid = Int(fields[0]) else { return nil }
        return (pid, String(fields[1]).trimmingCharacters(in: .whitespaces))
      }
      .filter { Self.matches(command: $0.command, expectedName: expectedName) }
      .map { "\(expectedName) (PID \($0.pid))" }
  }

  private static func matches(command: String, expectedName: String) -> Bool {
    var arguments = command
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    guard let executable = arguments.first else { return false }
    let executableName = URL(fileURLWithPath: executable).lastPathComponent
    if executableName == expectedName {
      return !isAppBundlePath(executable)
    }
    let interpreters = ["bash", "dash", "fish", "node", "nodejs", "python", "python3", "ruby", "sh", "zsh"]
    guard interpreters.contains(executableName.lowercased()) else { return false }
    arguments.removeFirst()
    while arguments.first?.hasPrefix("-") == true {
      arguments.removeFirst()
    }
    guard let script = arguments.first else { return false }
    return !isAppBundlePath(script)
      && URL(fileURLWithPath: script).lastPathComponent == expectedName
  }

  private static func isAppBundlePath(_ path: String) -> Bool {
    path.range(of: ".app/Contents/", options: .caseInsensitive) != nil
  }

  private static func loadProcessList() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = processArguments
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
