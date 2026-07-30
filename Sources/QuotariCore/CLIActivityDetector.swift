import Foundation

public struct CLIActivityProcess: Hashable, Sendable {
  enum Generation: Hashable, Sendable {
    case process(startTimeSeconds: UInt64, startTimeMicroseconds: UInt64)
    case legacy(String)
  }

  public let displayName: String
  let generation: Generation

  init(displayName: String, generation: Generation) {
    self.displayName = displayName
    self.generation = generation
  }

  init(legacyDisplayName: String) {
    displayName = legacyDisplayName
    generation = .legacy(legacyDisplayName)
  }
}

struct CLIActivityProcessRecord: Sendable {
  let pid: Int32
  let generation: CLIActivityProcess.Generation
  let arguments: [String]
}

/// A point-in-time list of CLI processes shown to the user before a credential
/// mutation. Passing this snapshot back to a mutation authorizes only these
/// exact processes for that one operation; a process launched afterwards still
/// fails the interlock.
public struct CLIActivitySnapshot: Equatable, Sendable {
  public let provider: UsageProvider
  public let processes: [String]
  private let approvedProcesses: Set<CLIActivityProcess>

  public init(provider: UsageProvider, processes: [String]) {
    self.provider = provider
    self.processes = Array(Set(processes)).sorted()
    approvedProcesses = Set(processes.map(CLIActivityProcess.init(legacyDisplayName:)))
  }

  init(provider: UsageProvider, processes: [CLIActivityProcess]) {
    self.provider = provider
    self.processes = Array(Set(processes.map(\.displayName))).sorted()
    approvedProcesses = Set(processes)
  }

  public var isActive: Bool {
    !processes.isEmpty
  }

  func unapprovedProcesses(
    for provider: UsageProvider,
    activeProcesses: [CLIActivityProcess]
  ) -> [String] {
    guard self.provider == provider else { return activeProcesses.map(\.displayName) }
    return activeProcesses
      .filter { !approvedProcesses.contains($0) }
      .map(\.displayName)
  }

  func unapprovedProcesses(for provider: UsageProvider, activeProcesses: [String]) -> [String] {
    unapprovedProcesses(
      for: provider,
      activeProcesses: activeProcesses.map(CLIActivityProcess.init(legacyDisplayName:))
    )
  }
}

enum CLIActivityApprovalContext {
  @TaskLocal static var snapshot: CLIActivitySnapshot?
}

public struct CLIActivityDetector: Sendable {
  static let processArguments = ["-x", "-o", "pid="]

  enum DetectionError: LocalizedError {
    case commandFailed(status: Int32)
    case argumentReadFailed(pid: Int32, code: Int32)
    case processInfoReadFailed(pid: Int32, code: Int32)
    case malformedOutput

    var errorDescription: String? {
      switch self {
      case let .commandFailed(status):
        "Inspecting running CLI processes failed (ps exited \(status))."
      case let .argumentReadFailed(pid, code):
        "Inspecting CLI process \(pid) failed (errno \(code))."
      case let .processInfoReadFailed(pid, code):
        "Inspecting CLI process generation \(pid) failed (errno \(code))."
      case .malformedOutput:
        "The running process list could not be decoded."
      }
    }
  }

  private let processes: @Sendable () throws -> [CLIActivityProcessRecord]

  public init() {
    processes = Self.loadProcesses
  }

  init(processes: @escaping @Sendable () throws -> [(pid: Int32, arguments: [String])]) {
    self.processes = {
      try processes().map { process in
        CLIActivityProcessRecord(
          pid: process.pid,
          generation: .legacy("pid-\(process.pid)"),
          arguments: process.arguments
        )
      }
    }
  }

  init(processesWithGenerations: @escaping @Sendable () throws -> [CLIActivityProcessRecord]) {
    processes = processesWithGenerations
  }

  /// Returns exact executable or interpreter-script name matches. Inspecting
  /// the command arguments is required for npm/shebang installations, whose
  /// executable image is an interpreter such as `node` or `bash`.
  public func activeProcesses(for provider: UsageProvider) throws -> [String] {
    try activeProcessRecords(for: provider).map(\.displayName)
  }

  public func activeProcessRecords(for provider: UsageProvider) throws -> [CLIActivityProcess] {
    let expectedName = switch provider {
    case .claude: "claude"
    case .codex: "codex"
    }
    return try processes()
      .filter { Self.matches(arguments: $0.arguments, expectedName: expectedName) }
      .map { process in
        CLIActivityProcess(
          displayName: "\(expectedName) (PID \(process.pid))",
          generation: process.generation
        )
      }
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
}
