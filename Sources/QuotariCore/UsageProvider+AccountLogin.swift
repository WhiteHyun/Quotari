extension UsageProvider {
  var accountLoginCLIName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    }
  }
}
