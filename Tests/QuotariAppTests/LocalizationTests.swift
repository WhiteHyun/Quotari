import Foundation
@testable import Quotari
import Testing

struct LocalizationTests {
  @Test func resolvesEnglishAndKoreanFromThePackagedResourceBundle() {
    #expect(L10n.string("General", locale: Locale(identifier: "en")) == "General")
    #expect(L10n.string("General", locale: Locale(identifier: "ko")) == "일반")
  }

  @Test func localizesUsageDurationsAndCountdowns() {
    let korean = Locale(identifier: "ko")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(LocalizedUsageFormatter.compactDuration(90000, locale: korean) == "1일 1시간")
    #expect(
      LocalizedUsageFormatter.resetCountdown(
        to: now.addingTimeInterval(3900),
        now: now,
        locale: korean
      ) == "1시간 5분 후"
    )
  }

  @Test func localizesDynamicUsageAndNotificationText() {
    let korean = Locale(identifier: "ko")
    #expect(L10n.string("Every \(5) minute(s)", locale: korean) == "5분마다")
    #expect(L10n.string("\(20)% in deficit", locale: korean) == "예상보다 20% 빠름")
    #expect(L10n.string("\("Codex") usage is at \("80")%.", locale: korean) == "Codex 사용량이 80%입니다.")
  }

  @Test func localizesWrappedAccountConfirmationText() {
    let korean = Locale(identifier: "ko")
    let account = "개인"
    let message = L10n.string(
      """
      Quit active Claude Code or Codex sessions first. Quotari will preserve the current login, then put \
      \(account) into the shared CLI slot.
      """,
      locale: korean
    )
    #expect(message.contains("개인 계정을 공유 CLI 슬롯에 적용합니다"))
  }
}
