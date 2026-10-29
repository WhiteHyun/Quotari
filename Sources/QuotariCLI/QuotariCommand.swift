import Foundation
import QuotariSharedSnapshot

/// The `quotari` command. It reads only the snapshot file the app writes; it
/// never reads credentials or calls a provider (ADR 0003).
enum QuotariCommand {
  struct Output: Equatable {
    var standardOutput = ""
    var standardError = ""
    var exitCode: Int32 = 0
  }

  enum Mode: Equatable {
    case summary
    case json
    case statusline
    case help
  }

  struct Invocation: Equatable {
    var mode = Mode.summary
    var provider: String?

    init(_ arguments: [String]) throws(UsageError) {
      var remaining = arguments[...]
      while let argument = remaining.popFirst() {
        switch argument {
        case "-h", "--help", "help":
          mode = .help
        case "--json":
          mode = .json
        case "statusline":
          mode = .statusline
        case "--provider":
          guard let value = remaining.popFirst() else {
            throw UsageError(message: "--provider needs a provider id.")
          }
          provider = value.lowercased()
        default:
          throw UsageError(message: "Unknown argument: \(argument)")
        }
      }
    }
  }

  struct UsageError: Error, Equatable {
    var message: String
  }

  static let usage = """
  Usage: quotari [statusline | --json] [--provider <id>]

  Prints the latest usage the Quotari app recorded. Reads only the snapshot
  file the app writes, never credentials or the network.

    quotari                Show each provider's quota windows.
    quotari statusline     Print one line for a terminal statusline.
    quotari --json         Print the snapshot as JSON.
    --provider <id>        Show one provider: claude or codex.
    -h, --help             Show this help.

  """

  static func run(_ arguments: [String], file: SharedUsageSnapshotFile, now: Date) -> Output {
    let invocation: Invocation
    do {
      invocation = try Invocation(arguments)
    } catch {
      return Output(standardError: "\(error.message)\n\n\(usage)", exitCode: 2)
    }
    if invocation.mode == .help {
      return Output(standardOutput: usage)
    }

    let snapshot: SharedUsageSnapshot
    switch file.read() {
    case let .snapshot(read):
      snapshot = read
    case .missing:
      return failure(
        invocation,
        statusline: "Quotari: no data",
        message: "No usage snapshot at \(file.url.path). Open Quotari and let it refresh once."
      )
    case .unreadable:
      return failure(
        invocation,
        statusline: "Quotari: unreadable data",
        message: "The usage snapshot at \(file.url.path) could not be read."
      )
    case let .newerVersion(version):
      return failure(
        invocation,
        statusline: "Quotari: update needed",
        message: "The usage snapshot uses schema version \(version), but this quotari reads up to "
          + "\(SharedUsageSnapshot.currentSchemaVersion). Update Quotari."
      )
    }

    var shown = snapshot
    if let provider = invocation.provider {
      shown.providers = snapshot.providers.filter { $0.id == provider }
    }
    return render(shown, mode: invocation.mode, now: now)
  }

  private static func render(_ snapshot: SharedUsageSnapshot, mode: Mode, now: Date) -> Output {
    switch mode {
    case .statusline:
      return Output(standardOutput: SnapshotRendering.statusline(snapshot.providers, now: now) + "\n")
    case .json:
      guard let data = try? SharedUsageSnapshotFile.encode(snapshot),
            let json = String(bytes: data, encoding: .utf8)
      else {
        return Output(standardError: "The usage snapshot could not be encoded.\n", exitCode: 1)
      }
      return Output(standardOutput: json + "\n")
    case .summary, .help:
      guard !snapshot.providers.isEmpty else {
        return Output(standardError: "No provider usage recorded yet.\n", exitCode: 1)
      }
      return Output(standardOutput: SnapshotRendering.summary(snapshot.providers, now: now))
    }
  }

  /// A statusline keeps its slot readable, so it reports problems on stdout and
  /// exits cleanly. The other modes fail like any command.
  private static func failure(_ invocation: Invocation, statusline: String, message: String) -> Output {
    invocation.mode == .statusline
      ? Output(standardOutput: statusline + "\n")
      : Output(standardError: message + "\n", exitCode: 1)
  }
}
