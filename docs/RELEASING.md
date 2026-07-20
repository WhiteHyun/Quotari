# Releasing Quotari

Quotari ships outside the App Store: a signed + notarized `.app` on GitHub
Releases, installable directly or via a Homebrew tap, with Sparkle keeping
direct-download users up to date.

## Automated release

The release script performs the complete direct-distribution flow:

1. Build a universal app and sign every nested Sparkle component bottom-up.
2. Notarize the ZIP, staple and verify the app, then recreate the ZIP.
3. Build a drag-to-Applications DMG, sign it, notarize it, and staple it.
4. Generate an EdDSA-signed Sparkle appcast that downloads the ZIP.
5. Publish the DMG, ZIP, and appcast together on GitHub Releases.

Run the interactive setup once:

```sh
Scripts/release.sh --setup --apple-id you@example.com
```

This creates a Quotari-specific Sparkle key in the login Keychain and stores
the Apple notarization credentials under `quotari-notary`. The app-specific
password is entered through the secure `notarytool` prompt and is never written
to the repository or shell history.

Then cut a release with one command:

```sh
Scripts/release.sh 0.1.0
```

Useful variants:

```sh
Scripts/release.sh 0.1.0 --draft
Scripts/release.sh 0.1.0 --no-publish
Scripts/release.sh 0.1.0 --notes-file release-notes.md
Scripts/release.sh 0.1.0 --dry-run
```

The script defaults to an `arm64 x86_64` universal build. Override `ARCHS`,
`CODESIGN_IDENTITY`, `NOTARY_PROFILE`, `SPARKLE_ACCOUNT`, or `RELEASE_TARGET`
through the environment when needed. By default, the script requires the clean
local commit to exactly match the remote `main` commit before publishing.

### Self-hosted GitHub Actions release

The `Release` workflow runs only when manually dispatched from `main` and
targets the dedicated `[self-hosted, macOS, ARM64, quotari-release]` runner.
Register that runner under a separate macOS user on the CICD Mac so it does not
share a Keychain or process namespace with pull-request runners. Create a GitHub
Environment named `release`, protect it with a required reviewer, and configure
these environment secrets:

- `DEVELOPER_ID_P12_BASE64`: base64-encoded Developer ID Application identity
- `DEVELOPER_ID_P12_PASSWORD`: password used to export that `.p12`
- `RELEASE_KEYCHAIN_PASSWORD`: a strong temporary-Keychain password
- `SPARKLE_PRIVATE_KEY`: private key exported with
  `generate_keys --account quotari -x <file>`
- `SPARKLE_PUBLIC_KEY`: public key printed by
  `generate_keys --account quotari -p`
- `NOTARY_API_KEY`: App Store Connect API private key contents
- `NOTARY_KEY_ID`: App Store Connect API key ID
- `NOTARY_ISSUER`: issuer UUID for a Team API key; leave empty for an
  Individual API key

The workflow imports the Developer ID identity into an ephemeral Keychain,
uses file-based Sparkle and notary credentials, and removes the temporary files
and Keychain after every run. Do not install release credentials permanently in
the shared runner user's login Keychain.

Create the notarized draft first:

```sh
gh workflow run release.yml --ref main \
  -f version=0.1.1 \
  -f action=draft
```

After testing the draft DMG and the Sparkle update, publish the same release:

```sh
gh workflow run release.yml --ref main \
  -f version=0.1.1 \
  -f action=publish
```

Because multiple repository runners currently share one physical Mac and user
account, run privileged release jobs under a dedicated macOS user before adding
production secrets. GitHub Environment approval protects workflow access, but
it does not provide operating-system isolation from another process running as
the same user.

## Manual release reference

The following commands document the underlying workflow for troubleshooting.

### One-time setup

1. **Developer ID certificate** — an Apple Developer Program membership with a
   "Developer ID Application" certificate in your keychain.
2. **Sparkle EdDSA keys** — generate once and keep the private key safe
   (it lands in your keychain):

   ```sh
   $(find .build -name generate_keys -type f | head -1) --account quotari
   ```

   Record the printed public key; it goes into every build as `SPARKLE_PUBLIC_KEY`.
3. **Notarization profile** — store credentials once:

   ```sh
   xcrun notarytool store-credentials quotari-notary \
     --apple-id you@example.com --team-id TEAMID --password <app-specific>
   ```

### Cutting a release

```sh
# 1. Build, bundle, and sign
VERSION=0.1.0 \
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SPARKLE_PUBLIC_KEY="<public key from setup>" \
Scripts/package-app.sh

# 2. Notarize and staple
xcrun notarytool submit dist/Quotari-0.1.0.zip --keychain-profile quotari-notary --wait
xcrun stapler staple dist/Quotari.app
ditto -c -k --keepParent dist/Quotari.app dist/Quotari-0.1.0.zip   # re-zip stapled app

# 3. Generate the Sparkle appcast (signs the zip with your private key)
$(find .build -name generate_appcast -type f | head -1) \
  --account quotari dist/

# 4. Publish
gh release create v0.1.0 dist/Quotari-0.1.0.zip dist/appcast.xml \
  --title "Quotari 0.1.0" --notes "..."
```

The app's feed URL points at
`releases/latest/download/appcast.xml`, so attaching `appcast.xml` to the
latest release is what makes older installs see the update.

## Homebrew tap

Create a `WhiteHyun/homebrew-tap` repository once, then add/update
`Casks/quotari.rb` per release:

```ruby
cask "quotari" do
  version "0.1.0"
  sha256 "<shasum -a 256 dist/Quotari-0.1.0.zip>"

  url "https://github.com/WhiteHyun/Quotari/releases/download/v#{version}/Quotari-#{version}.zip"
  name "Quotari"
  desc "Menu-bar usage, limits, and reset times for AI coding subscriptions"
  homepage "https://github.com/WhiteHyun/Quotari"

  app "Quotari.app"
end
```

Users then install with `brew install --cask whitehyun/tap/quotari`. Homebrew
manages updates for tap installs; Sparkle covers direct downloads. (If both are
active the two won't conflict — Sparkle only replaces the app it runs from —
but consider disabling the feed for cask builds later.)

## Notes

- Without `SPARKLE_PUBLIC_KEY`, `package-app.sh` omits the Sparkle feed keys and
  the app runs with updates disabled — useful for local packaging tests.
- Without `CODESIGN_IDENTITY`, the script ad-hoc signs; fine locally, but
  Gatekeeper will block it on other machines. Real releases must be signed and
  notarized.
- `package-app.sh` copies the SwiftPM resource bundle into `Contents/Resources`,
  verifies the complete code signature, then launches an isolated copy with a
  resource smoke-check argument before creating the zip.
- `package-app.sh` defaults to arm64 for quick local packaging. The automated
  release script passes `ARCHS="arm64 x86_64"` to produce a universal binary.
