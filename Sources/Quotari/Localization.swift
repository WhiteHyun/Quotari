import Foundation

enum L10n {
  static var packagedResourcesAreReady: Bool {
    string("General", locale: Locale(identifier: "ko")) == "일반"
  }

  static func string(
    _ value: String.LocalizationValue,
    locale: Locale = .current,
    comment: StaticString? = nil
  ) -> String {
    String(
      localized: value,
      bundle: localizedBundle(for: locale),
      locale: locale,
      comment: comment
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
