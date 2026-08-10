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
    #expect(L10n.string("Couldn’t remove mascot", locale: korean) == "마스코트를 삭제할 수 없음")
    #expect(L10n.string("Remove custom mascot?", locale: korean) == "커스텀 마스코트를 삭제할까요?")
    #expect(
      L10n.string(
        "Quotari couldn’t remove the custom mascot.",
        locale: korean
      ) == "Quotari가 커스텀 마스코트를 삭제하지 못했습니다."
    )
    #expect(
      L10n.string(
        "This removes Quotari’s saved copy. You’ll need to import the original PNG files again.",
        locale: korean
      ) == "Quotari에 저장된 사본이 삭제됩니다. 다시 사용하려면 원본 PNG 파일을 가져와야 합니다."
    )
    #expect(
      L10n.string(
        "Wait for the current custom mascot operation to finish.",
        locale: korean
      ) == "진행 중인 커스텀 마스코트 작업이 끝날 때까지 기다려 주세요."
    )
  }

  @Test func localizesSharedUsageProvenanceAndLimitations() {
    let korean = Locale(identifier: "ko")

    #expect(
      L10n.string(
        "Estimated from local Codex logs (not account-specific)",
        locale: korean
      ) == "로컬 Codex 로그에서 추정(계정별 데이터 아님)"
    )
    #expect(
      L10n.string(
        "Partial estimate · unsupported token fields",
        locale: korean
      ) == "일부 추정 · 지원하지 않는 토큰 필드"
    )
  }

  @Test func localizesCompactUsageInsights() {
    let korean = Locale(identifier: "ko")

    #expect(L10n.string("Usage insights", locale: korean) == "사용량 인사이트")
    #expect(L10n.string("7D", locale: korean) == "7일")
    #expect(L10n.string("Partial pricing", locale: korean) == "일부 가격만 반영")
    #expect(L10n.string("Sessions", locale: korean) == "세션")
    #expect(LocalizedUsageFormatter.tokenCount(32000, locale: korean) == "32K 토큰")
    #expect(
      L10n.string(key: "Estimated from local Codex logs", locale: korean)
        == "로컬 Codex 로그에서 추정"
    )
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

  @Test func localizesBlockedClaudeSwitchGuidance() {
    let korean = Locale(identifier: "ko")
    let key = "Running Claude Code sessions: %@. Quit all of them, then try again. "
      + "Quotari will not switch the CLI account while a session is running."
    let message = String.localizedStringWithFormat(
      L10n.string(key: key, locale: korean),
      "claude (PID 42)"
    )

    #expect(
      L10n.string("Quit Claude Code before switching", locale: korean)
        == "계정을 전환하려면 Claude Code를 종료하세요"
    )
    #expect(
      message
        == "실행 중인 Claude Code 세션: claude (PID 42). 모든 세션을 종료한 다음 다시 시도하세요. "
        + "세션이 실행 중인 동안에는 Quotari가 CLI 계정을 전환하지 않습니다."
    )
  }
}
