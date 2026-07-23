import Foundation
import PackagePlugin

@main
struct CompileStringCatalogPlugin: BuildToolPlugin {
  func createBuildCommands(
    context: PluginContext,
    target: Target
  ) throws -> [Command] {
    let catalog = target.directoryURL
      .appendingPathComponent("Resources/Localizable.xcstrings")
    let languages = try localizedLanguageCodes(in: catalog)
    let outputDirectory = context.pluginWorkDirectoryURL
      .appendingPathComponent("CompiledStringCatalog")
    let outputFiles = languages.map {
      outputDirectory
        .appendingPathComponent("\($0).lproj")
        .appendingPathComponent("Localizable.strings")
    }

    return [
      .buildCommand(
        displayName: "Compiling Localizable.xcstrings",
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: [
          "xcstringstool",
          "compile",
          catalog.path,
          "--output-directory",
          outputDirectory.path,
          "--serialization-format",
          "binary",
        ],
        inputFiles: [catalog],
        outputFiles: outputFiles
      ),
    ]
  }

  private func localizedLanguageCodes(in catalog: URL) throws -> [String] {
    let data = try Data(contentsOf: catalog)
    let catalog = try JSONDecoder().decode(StringCatalog.self, from: data)
    let languages = Set(
      catalog.strings.values.flatMap { entry in
        entry.localizations?.keys ?? [:].keys
      }
    )

    guard !languages.isEmpty else {
      throw StringCatalogPluginError.noLocalizations
    }
    return languages.sorted()
  }
}

private struct StringCatalog: Decodable {
  let strings: [String: StringCatalogEntry]
}

private struct StringCatalogEntry: Decodable {
  let localizations: [String: StringCatalogLocalization]?
}

private struct StringCatalogLocalization: Decodable {}

private enum StringCatalogPluginError: Error, CustomStringConvertible {
  case noLocalizations

  var description: String {
    switch self {
    case .noLocalizations:
      "Localizable.xcstrings does not contain any localized languages."
    }
  }
}
