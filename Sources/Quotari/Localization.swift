import Foundation

enum L10n {
  private static let sourceLanguage = "en"

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

  private static var appLocale: Locale {
    guard let supportedLocalizations = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleLocalizations"
    ) as? [String], !supportedLocalizations.isEmpty
    else { return Locale(identifier: sourceLanguage) }

    return Locale(
      identifier: preferredLanguageCode(
        supportedLocalizations: supportedLocalizations,
        preferredLanguages: Bundle.main.preferredLocalizations
      )
    )
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
