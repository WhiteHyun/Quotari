import Darwin
import Foundation

public struct CLIActivityDetector: Sendable {
  static let processArguments = ["-x", "-o", "pid="]

  enum DetectionError: LocalizedError {
    case commandFailed(status: Int32)
    case argumentReadFailed(pid: Int32, code: Int32)
    case malformedOutput

    var errorDescription: String? {
      switch self {
      case let .commandFailed(status):
        "Inspecting running CLI processes failed (ps exited \(status))."
      case let .argumentReadFailed(pid, code):
        "Inspecting CLI process \(pid) failed (errno \(code))."
      case .malformedOutput:
        "The running process list could not be decoded."
      }
    }
  }

  private let processes: @Sendable () throws -> [(pid: Int32, arguments: [String])]

  public init() {
    processes = Self.loadProcesses
  }

  init(processes: @escaping @Sendable () throws -> [(pid: Int32, arguments: [String])]) {
    self.processes = processes
  }

  /// Returns exact executable or interpreter-script name matches. Inspecting
  /// the command arguments is required for npm/shebang installations, whose
  /// executable image is an interpreter such as `node` or `bash`.
  public func activeProcesses(for provider: UsageProvider) throws -> [String] {
    let expectedName = switch provider {
    case .claude: "claude"
    case .codex: "codex"
    }
    return try processes()
      .filter { Self.matches(arguments: $0.arguments, expectedName: expectedName) }
      .map { "\(expectedName) (PID \($0.pid))" }
  }

  private static func matches(arguments originalArguments: [String], expectedName: String) -> Bool {
    let arguments = originalArguments
    guard let executable = arguments.first else { return false }
    let executableName = URL(fileURLWithPath: executable).lastPathComponent
    if executableName == expectedName {
      return !isAppBundlePath(executable)
    }
    let interpreters = ["bash", "dash", "fish", "node", "nodejs", "python", "python3", "ruby", "sh", "zsh"]
    guard interpreters.contains(executableName.lowercased()) else { return false }
    guard let script = interpreterScript(
      in: Array(arguments.dropFirst()),
      interpreter: executableName.lowercased()
    ) else { return false }
    return !isAppBundlePath(script)
      && URL(fileURLWithPath: script).lastPathComponent == expectedName
  }

  private static func interpreterScript(
    in arguments: [String],
    interpreter: String
  ) -> String? {
    let valueOptions = interpreterValueOptions[interpreter, default: []]
    let inlineValueOptions = interpreterInlineValueOptions[interpreter, default: []]
    let commandOptions = interpreterCommandOptions[interpreter, default: []]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--" {
        return arguments.dropFirst(index + 1).first
      }
      guard argument.hasPrefix("-") else { return argument }
      let isInlineCommand = commandOptions.contains { option in
        inlineValueOptions.contains(option)
          && argument.count > option.count
          && argument.hasPrefix(option)
      }
      if commandOptions.contains(argument)
        || commandOptions.contains(where: { argument.hasPrefix("\($0)=") })
        || isInlineCommand {
        return nil
      }
      switch shortOptionCluster(
        argument,
        valueOptions: valueOptions,
        commandOptions: commandOptions
      ) {
      case .command:
        return nil
      case let .value(consumesNext):
        index += consumesNext ? 2 : 1
        continue
      case .flags:
        break
      }
      if valueOptions.contains(argument) {
        index += 2
      } else {
        index += 1
      }
    }
    return nil
  }

  private enum ShortOptionCluster {
    case command
    case value(consumesNext: Bool)
    case flags
  }

  private static func shortOptionCluster(
    _ argument: String,
    valueOptions: Set<String>,
    commandOptions: Set<String>
  ) -> ShortOptionCluster {
    guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return .flags }
    let flags = Array(argument.dropFirst())
    for (index, flag) in flags.enumerated() {
      let option = "-\(flag)"
      if commandOptions.contains(option) {
        return .command
      }
      if valueOptions.contains(option) {
        return .value(consumesNext: index == flags.index(before: flags.endIndex))
      }
    }
    return .flags
  }

  private static let interpreterValueOptions: [String: Set<String>] = [
    "bash": ["--init-file", "--rcfile", "-O", "-o"],
    "dash": ["-o"],
    "fish": ["--init-command", "-C"],
    "node": ["--conditions", "--experimental-loader", "--import", "--loader", "--require", "-C", "-r"],
    "nodejs": ["--conditions", "--experimental-loader", "--import", "--loader", "--require", "-C", "-r"],
    "python": ["--check-hash-based-pycs", "-W", "-X"],
    "python3": ["--check-hash-based-pycs", "-W", "-X"],
    "ruby": ["--encoding", "--external-encoding", "--internal-encoding", "-C", "-E", "-F", "-I", "-K", "-r"],
    "sh": ["-o"],
    "zsh": ["-o"],
  ]

  private static let interpreterInlineValueOptions: [String: Set<String>] = [
    "node": ["-C", "-e", "-p", "-r"],
    "nodejs": ["-C", "-e", "-p", "-r"],
    "python": ["-W", "-X", "-c", "-m"],
    "python3": ["-W", "-X", "-c", "-m"],
    "ruby": ["-C", "-E", "-F", "-I", "-K", "-e", "-r"],
  ]

  private static let interpreterCommandOptions: [String: Set<String>] = [
    "bash": ["-c"],
    "dash": ["-c"],
    "fish": ["--command", "-c"],
    "node": ["--eval", "--print", "-e", "-p"],
    "nodejs": ["--eval", "--print", "-e", "-p"],
    "python": ["-c", "-m"],
    "python3": ["-c", "-m"],
    "ruby": ["-e"],
    "sh": ["-c"],
    "zsh": ["-c"],
  ]

  private static func isAppBundlePath(_ path: String) -> Bool {
    path.range(of: ".app/Contents/", options: .caseInsensitive) != nil
  }

  private static func loadProcesses() throws -> [(pid: Int32, arguments: [String])] {
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
    let pids = try text.split(separator: "\n").map { line -> Int32 in
      guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else {
        throw DetectionError.malformedOutput
      }
      return pid
    }
    return try pids.compactMap { pid in
      guard let arguments = try loadProcessArguments(pid: pid) else { return nil }
      return (pid, arguments)
    }
  }

  private static func loadProcessArguments(pid: Int32) throws -> [String]? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
      if errno == ESRCH || errno == EINVAL {
        return nil
      }
      throw DetectionError.argumentReadFailed(pid: pid, code: errno)
    }
    var bytes = [UInt8](repeating: 0, count: size)
    let status = bytes.withUnsafeMutableBytes { buffer in
      sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
    }
    guard status == 0 else {
      if errno == ESRCH || errno == EINVAL {
        return nil
      }
      throw DetectionError.argumentReadFailed(pid: pid, code: errno)
    }
    return try decodeProcessArguments(Array(bytes.prefix(size)))
  }

  static func decodeProcessArguments(_ bytes: [UInt8]) throws -> [String] {
    guard bytes.count >= MemoryLayout<Int32>.size else {
      throw DetectionError.malformedOutput
    }
    var argumentCount: Int32 = 0
    withUnsafeMutableBytes(of: &argumentCount) { destination in
      destination.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
    }
    guard argumentCount >= 0 else { throw DetectionError.malformedOutput }
    var index = MemoryLayout<Int32>.size
    while index < bytes.count, bytes[index] != 0 {
      index += 1
    }
    guard index < bytes.count else { throw DetectionError.malformedOutput }
    while index < bytes.count, bytes[index] == 0 {
      index += 1
    }

    var arguments: [String] = []
    for _ in 0 ..< Int(argumentCount) {
      let start = index
      while index < bytes.count, bytes[index] != 0 {
        index += 1
      }
      guard index < bytes.count else { throw DetectionError.malformedOutput }
      guard let argument = String(bytes: bytes[start ..< index], encoding: .utf8) else {
        throw DetectionError.malformedOutput
      }
      arguments.append(argument)
      index += 1
    }
    return arguments
  }
}
