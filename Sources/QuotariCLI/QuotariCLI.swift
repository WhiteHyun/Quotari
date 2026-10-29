import Foundation
import QuotariSharedSnapshot

@main
enum QuotariCLI {
  static func main() {
    let output = QuotariCommand.run(
      Array(CommandLine.arguments.dropFirst()),
      file: SharedUsageSnapshotFile(),
      now: Date()
    )
    FileHandle.standardOutput.write(Data(output.standardOutput.utf8))
    FileHandle.standardError.write(Data(output.standardError.utf8))
    exit(output.exitCode)
  }
}
