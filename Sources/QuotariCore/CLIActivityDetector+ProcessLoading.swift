import Darwin
import Foundation

extension CLIActivityDetector {
  static func loadProcesses() throws -> [CLIActivityProcessRecord] {
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
    let pids = try candidateProcessIDs(from: text)
    return try pids.compactMap(processRecord)
  }

  /// `proc_pidinfo` can deny access to unrelated same-user processes (for
  /// example, the login shell host). Use `ps` only as a conservative prefilter
  /// so those processes cannot make the entire CLI safety check fail. Every
  /// plausible Claude or Codex process is still validated through the kernel
  /// APIs below before it can be approved for a credential mutation.
  static func candidateProcessIDs(from output: String) throws -> [Int32] {
    try output.split(separator: "\n").compactMap { line in
      let fields = line.split(
        maxSplits: 1,
        omittingEmptySubsequences: true,
        whereSeparator: \Character.isWhitespace
      )
      guard let pidField = fields.first, let pid = Int32(pidField) else {
        throw DetectionError.malformedOutput
      }
      guard fields.count == 2, mayContainCLI(String(fields[1])) else { return nil }
      return pid
    }
  }

  private static func mayContainCLI(_ command: String) -> Bool {
    let fields = command.split(whereSeparator: \Character.isWhitespace)
    var commandPrefix = ""
    var interpreterFieldIndex: Int?
    for (index, field) in fields.enumerated() {
      commandPrefix += commandPrefix.isEmpty ? String(field) : " \(field)"
      if isCLITarget(commandPrefix) {
        return true
      }
      if interpreterFieldIndex == nil, isSupportedInterpreter(commandPrefix) {
        interpreterFieldIndex = index
      }
    }
    guard let interpreterFieldIndex else { return false }
    return fields.dropFirst(interpreterFieldIndex + 1).contains {
      isCLITarget(String($0))
    }
  }

  private static func isSupportedInterpreter(_ path: String) -> Bool {
    let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    return ["bash", "dash", "fish", "node", "nodejs", "python", "python3", "ruby", "sh", "zsh"]
      .contains(name)
  }

  private static func isCLITarget(_ path: String) -> Bool {
    guard !isAppBundlePath(path) else { return false }
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name == "claude" || name == "codex"
  }

  private static func processRecord(pid: Int32) throws -> CLIActivityProcessRecord? {
    guard let generationBefore = try loadProcessGeneration(pid: pid),
          let arguments = try loadProcessArguments(pid: pid),
          let generationAfter = try loadProcessGeneration(pid: pid),
          generationBefore == generationAfter
    else { return nil }
    return CLIActivityProcessRecord(
      pid: pid,
      generation: generationAfter,
      arguments: arguments
    )
  }

  private static func loadProcessGeneration(pid: Int32) throws -> CLIActivityProcess.Generation? {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    errno = 0
    let readSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
    guard readSize == expectedSize else {
      if readSize == 0, errno == ESRCH || errno == EINVAL {
        return nil
      }
      throw DetectionError.processInfoReadFailed(pid: pid, code: errno)
    }
    return .process(
      startTimeSeconds: info.pbi_start_tvsec,
      startTimeMicroseconds: info.pbi_start_tvusec
    )
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
    return try decodeArguments(bytes, count: Int(argumentCount), startingAt: index)
  }

  private static func decodeArguments(_ bytes: [UInt8], count: Int, startingAt start: Int) throws -> [String] {
    var index = start
    var arguments: [String] = []
    for _ in 0 ..< count {
      let argumentStart = index
      while index < bytes.count, bytes[index] != 0 {
        index += 1
      }
      guard index < bytes.count,
            let argument = String(bytes: bytes[argumentStart ..< index], encoding: .utf8)
      else { throw DetectionError.malformedOutput }
      arguments.append(argument)
      index += 1
    }
    return arguments
  }
}
