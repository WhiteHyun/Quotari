import Foundation
@testable import Quotari
import QuotariCore
import Testing

struct LocalizationTests {
  @Test func resolvesEnglishAndKoreanFromThePackagedResourceBundle() {
    #expect(L10n.string("General", locale: Locale(identifier: "en")) == "General")
    #expect(L10n.string("General", locale: Locale(identifier: "ko")) == "일반")
  }

  @Test func resolvesTheLanguageSelectedForTheAppInsteadOfTheFormattingLocale() {
    #expect(L10n.supportedLanguageCodes.contains("ko"))
    #expect(
      L10n.preferredLanguageCode(
        supportedLocalizations: ["en", "ko"],
        preferredLanguages: ["ko-KR", "en-US"]
      ) == "ko"
    )
    #expect(
      L10n.preferredLanguageCode(
        supportedLocalizations: ["en", "ko"],
        preferredLanguages: ["ja-JP"]
      ) == "en"
    )
  }

  @Test func localizesTheDuplicateClaudeAccountError() {
    let korean = Locale(identifier: "ko")
    #expect(
      L10n.string(
        "More than one saved Claude account has this identity. Resolve the duplicate accounts before logging in again.",
        locale: korean
      ) == "같은 신원을 가진 저장된 Claude 계정이 둘 이상입니다. 다시 로그인하기 전에 중복 계정을 정리하세요."
    )
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

  @Test func localizesCustomMascotSettings() {
    let korean = Locale(identifier: "ko")

    #expect(L10n.string("Mascot", locale: korean) == "마스코트")
    #expect(L10n.string("Built-in Flame", locale: korean) == "기본 불꽃")
    #expect(L10n.string("Custom mascot", locale: korean) == "커스텀 마스코트")
    #expect(L10n.string("Import…", locale: korean) == "가져오기…")
  }

  @Test func hidesPaceTrendsBelowOnePercentBeforeRounding() {
    let pace = UsagePace(deltaPercent: 0.75, runsOutIn: nil, headroomMultiplier: nil)

    #expect(LocalizedUsageFormatter.paceTrend(pace, locale: Locale(identifier: "en")) == nil)
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
