import Foundation

enum L10n {
  private static let sourceLanguage = "en"

  static var appLocale: Locale {
    Locale(
      identifier: preferredLanguageCode(
        supportedLocalizations: supportedLanguageCodes,
        preferredLanguages: appPreferredLanguages
      )
    )
  }

  static var supportedLanguageCodes: [String] {
    ([sourceLanguage] + IconRenderer.resourceBundle.localizations).reduce(into: []) { languages, localization in
      let language = Locale(identifier: localization).language.languageCode?.identifier ?? localization
      if !languages.contains(language) {
        languages.append(language)
      }
    }
  }

  static var packagedResourcesAreReady: Bool {
    string("General", locale: Locale(identifier: "ko")) == "일반"
  }

  static func string(
    _ value: String.LocalizationValue,
    locale: Locale? = nil,
    comment: StaticString? = nil
  ) -> String {
    let locale = locale ?? appLocale
    return String(
      localized: value,
      bundle: localizedBundle(for: locale),
      locale: locale,
      comment: comment
    )
  }

  static func preferredLanguageCode(
    supportedLocalizations: [String],
    preferredLanguages: [String]
  ) -> String {
    Bundle.preferredLocalizations(
      from: supportedLocalizations,
      forPreferences: preferredLanguages
    ).first ?? sourceLanguage
  }

  private static var appPreferredLanguages: [String] {
    // A test host has no app-level language selection. Keep non-localization
    // tests deterministic while the real executable follows user preferences.
    if Bundle.main.bundleURL.pathExtension == "xctest" {
      return [sourceLanguage]
    }
    if let advertised = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleLocalizations"
    ) as? [String], !advertised.isEmpty {
      return Bundle.main.preferredLocalizations
    }
    return Locale.preferredLanguages
  }

  private static func localizedBundle(for locale: Locale) -> Bundle {
    guard let language = locale.language.languageCode?.identifier,
          let url = IconRenderer.resourceBundle.url(
            forResource: language,
            withExtension: "lproj"
          ),
          let bundle = Bundle(url: url)
    else { return IconRenderer.resourceBundle }
    return bundle
  }
}
