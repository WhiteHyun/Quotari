/// How quota rows say when a window resets.
enum ResetTimeStyle: String, CaseIterable, Codable, Sendable {
  /// "in 2h 13m"
  case countdown
  /// "15:30", "tomorrow 01:30", "Fri 09:00", "Nov 12"
  case clockTime
  /// "in 2h 13m · 15:30"
  case both
}
