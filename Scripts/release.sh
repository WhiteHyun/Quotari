#!/bin/zsh
# Builds, signs, notarizes, verifies, and publishes a Quotari release.
#
# One-time setup:
#   Scripts/release.sh --setup --apple-id you@example.com
#
# Release:
#   Scripts/release.sh 0.1.0
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

REPOSITORY="${REPOSITORY:-WhiteHyun/Quotari}"
RELEASE_TARGET="${RELEASE_TARGET:-main}"
TEAM_ID="${TEAM_ID:-2ZQR76M3UH}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: SeungHyun Hong (${TEAM_ID})}"
NOTARY_PROFILE="${NOTARY_PROFILE:-quotari-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-quotari}"
ARCHS="${ARCHS:-arm64 x86_64}"
SPARKLE_PUBLIC_KEY_OVERRIDE="${SPARKLE_PUBLIC_KEY:-}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"

MODE="release"
VERSION=""
APPLE_ID=""
NOTES_FILE=""
DRY_RUN=0
DRAFT=0
PUBLISH=1
RELEASE_WORK_ROOT=""

usage() {
  cat <<'USAGE'
Usage:
  Scripts/release.sh --setup --apple-id <Apple ID>
  Scripts/release.sh <version> [options]

Release options:
  --notes-file <path>  Use a release-notes file instead of GitHub-generated notes.
  --draft              Create a draft GitHub Release.
  --no-publish         Produce and verify artifacts without creating a GitHub Release.
  --dry-run            Print the release commands without executing them.
  -h, --help           Show this help.

Environment overrides:
  CODESIGN_IDENTITY, NOTARY_PROFILE, SPARKLE_ACCOUNT, ARCHS, REPOSITORY,
  RELEASE_TARGET, TEAM_ID, SPARKLE_PUBLIC_KEY, SPARKLE_PRIVATE_KEY_FILE,
  NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
USAGE
}

die() {
  print -u2 -- "error: $*"
  exit 1
}

log() {
  print -- "\n▸ $*"
}

run() {
  if (( DRY_RUN )); then
    printf '  $'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

cleanup() {
  [[ -z "$RELEASE_WORK_ROOT" ]] || rm -rf "$RELEASE_WORK_ROOT"
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

find_sparkle_tool() {
  local name="$1"
  local preferred="$ROOT/.build/artifacts/sparkle/Sparkle/bin/$name"
  if [[ -x "$preferred" ]]; then
    print -r -- "$preferred"
    return
  fi

  local candidate
  candidate=$(find "$ROOT/.build" -type f -name "$name" 2>/dev/null | head -1)
  [[ -n "$candidate" && -x "$candidate" ]] || die "Sparkle tool not found: $name"
  print -r -- "$candidate"
}

require_signing_identity() {
  security find-identity -v -p codesigning | grep -Fq "\"${CODESIGN_IDENTITY}\"" ||
    die "Developer ID identity is unavailable: ${CODESIGN_IDENTITY}"
}

notary_auth_arguments() {
  if [[ -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER" ]]; then
    [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" ]] ||
      die "NOTARY_KEY and NOTARY_KEY_ID must be provided together"
    [[ -f "$NOTARY_KEY" ]] || die "notary API key not found: $NOTARY_KEY"

    print -r -- "--key"
    print -r -- "$NOTARY_KEY"
    print -r -- "--key-id"
    print -r -- "$NOTARY_KEY_ID"
    if [[ -n "$NOTARY_ISSUER" ]]; then
      print -r -- "--issuer"
      print -r -- "$NOTARY_ISSUER"
    fi
  else
    print -r -- "--keychain-profile"
    print -r -- "$NOTARY_PROFILE"
  fi
}

setup_release_credentials() {
  [[ -n "$APPLE_ID" ]] || die "--setup requires --apple-id"
  require_command security
  require_command swift
  require_command xcrun
  if (( ! DRY_RUN )); then
    require_signing_identity
  fi

  log "resolving Sparkle tools"
  run swift package resolve

  local generate_keys
  if (( DRY_RUN )); then
    generate_keys="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
  else
    generate_keys=$(find_sparkle_tool generate_keys)
  fi

  log "creating or reusing the Quotari Sparkle signing key"
  run "$generate_keys" --account "$SPARKLE_ACCOUNT"

  log "storing Apple notarization credentials in Keychain"
  run xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID"

  print -- "\nSetup complete. Release with: Scripts/release.sh <version>"
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --setup)
        MODE="setup"
        ;;
      --apple-id)
        (( $# >= 2 )) || die "--apple-id requires a value"
        APPLE_ID="$2"
        shift
        ;;
      --notes-file)
        (( $# >= 2 )) || die "--notes-file requires a path"
        NOTES_FILE="$2"
        shift
        ;;
      --draft)
        DRAFT=1
        ;;
      --no-publish)
        PUBLISH=0
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "$VERSION" ]] || die "only one version may be provided"
        VERSION="$1"
        ;;
    esac
    shift
  done
}

release_preflight() {
  require_command codesign
  require_command ditto
  require_command gh
  require_command git
  require_command hdiutil
  require_command security
  require_command spctl
  require_command swift
  require_command xcrun

  [[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] ||
    die "version must use X.Y.Z format"
  [[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || die "notes file not found: $NOTES_FILE"
  if [[ -n "$SPARKLE_PUBLIC_KEY_OVERRIDE" || -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    [[ -n "$SPARKLE_PUBLIC_KEY_OVERRIDE" && -n "$SPARKLE_PRIVATE_KEY_FILE" ]] ||
      die "SPARKLE_PUBLIC_KEY and SPARKLE_PRIVATE_KEY_FILE must be provided together"
    [[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]] ||
      die "Sparkle private key not found: $SPARKLE_PRIVATE_KEY_FILE"
  fi

  if (( DRY_RUN )); then
    return
  fi

  [[ -z "$(git status --porcelain)" ]] || die "release from a clean workspace"
  require_signing_identity
  gh auth status >/dev/null
  local -a notary_arguments
  notary_arguments=("${(@f)$(notary_auth_arguments)}")
  xcrun notarytool history "${notary_arguments[@]}" >/dev/null

  local local_commit remote_commit
  local_commit=$(git rev-parse HEAD)
  remote_commit=$(gh api "repos/${REPOSITORY}/commits/${RELEASE_TARGET}" --jq .sha)
  [[ "$local_commit" == "$remote_commit" ]] ||
    die "local HEAD does not match ${REPOSITORY}@${RELEASE_TARGET}"

  local tag="v${VERSION}"
  if gh release view "$tag" --repo "$REPOSITORY" >/dev/null 2>&1; then
    die "GitHub Release already exists: $tag"
  fi
  if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    die "Git tag already exists: $tag"
  fi
}

create_release() {
  local tag="v${VERSION}"
  local app="$ROOT/dist/Quotari.app"
  local zip="$ROOT/dist/Quotari-${VERSION}.zip"
  local dmg="$ROOT/dist/Quotari-${VERSION}.dmg"
  local appcast="$ROOT/dist/appcast.xml"
  local release_download_url="https://github.com/${REPOSITORY}/releases/download/${tag}"

  local work_root
  if (( DRY_RUN )); then
    work_root="${TMPDIR:-/tmp}/quotari-release-dry-run"
  else
    work_root=$(mktemp -d "${TMPDIR:-/tmp}/quotari-release.XXXXXX")
    RELEASE_WORK_ROOT="$work_root"
  fi
  local update_root="$work_root/updates"

  log "resolving Sparkle tools and public key"
  run swift package resolve

  local generate_keys generate_appcast sparkle_public_key
  if (( DRY_RUN )); then
    generate_appcast="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
    if [[ -n "$SPARKLE_PUBLIC_KEY_OVERRIDE" ]]; then
      sparkle_public_key="<Sparkle public key from SPARKLE_PUBLIC_KEY>"
    else
      generate_keys="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
      sparkle_public_key="<Sparkle public key from Keychain account ${SPARKLE_ACCOUNT}>"
      run "$generate_keys" --account "$SPARKLE_ACCOUNT" -p
    fi
  else
    generate_appcast=$(find_sparkle_tool generate_appcast)
    if [[ -n "$SPARKLE_PUBLIC_KEY_OVERRIDE" ]]; then
      sparkle_public_key="$SPARKLE_PUBLIC_KEY_OVERRIDE"
    else
      generate_keys=$(find_sparkle_tool generate_keys)
      sparkle_public_key=$("$generate_keys" --account "$SPARKLE_ACCOUNT" -p)
    fi
    [[ -n "$sparkle_public_key" ]] || die "Sparkle public key is empty"
  fi

  local -a notary_arguments appcast_signing_arguments
  notary_arguments=("${(@f)$(notary_auth_arguments)}")
  if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    appcast_signing_arguments=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
  else
    appcast_signing_arguments=(--account "$SPARKLE_ACCOUNT")
  fi

  log "building and Developer ID signing Quotari ${VERSION} (${ARCHS})"
  run env \
    "VERSION=$VERSION" \
    "ARCHS=$ARCHS" \
    "CODESIGN_IDENTITY=$CODESIGN_IDENTITY" \
    "SPARKLE_PUBLIC_KEY=$sparkle_public_key" \
    "$ROOT/Scripts/package-app.sh"

  log "notarizing the Sparkle ZIP"
  run xcrun notarytool submit "$zip" "${notary_arguments[@]}" --wait
  run xcrun stapler staple "$app"
  run xcrun stapler validate "$app"
  run codesign --verify --deep --strict --verbose=2 "$app"
  run spctl --assess --type execute --verbose=4 "$app"

  log "repacking the stapled app for Sparkle"
  run rm -f "$zip"
  run ditto -c -k --keepParent --norsrc "$app" "$zip"

  log "creating the drag-to-Applications DMG"
  run mkdir -p "$update_root"
  run env \
    "CODESIGN_IDENTITY=$CODESIGN_IDENTITY" \
    "$ROOT/Scripts/create-dmg.sh" "$app" "$dmg"

  log "notarizing and stapling the DMG"
  run xcrun notarytool submit "$dmg" "${notary_arguments[@]}" --wait
  run xcrun stapler staple "$dmg"
  run xcrun stapler validate "$dmg"
  run hdiutil verify "$dmg"
  run spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"

  log "generating the signed Sparkle appcast"
  run ditto "$zip" "$update_root/Quotari-${VERSION}.zip"
  run "$generate_appcast" \
    "${appcast_signing_arguments[@]}" \
    --download-url-prefix "${release_download_url}/" \
    --link "https://github.com/${REPOSITORY}" \
    --versions "$VERSION" \
    "$update_root"
  run ditto "$update_root/appcast.xml" "$appcast"

  if (( ! DRY_RUN )); then
    [[ -s "$appcast" ]] || die "appcast was not generated"
    grep -q 'sparkle:edSignature=' "$appcast" || die "appcast is missing its EdDSA signature"
    grep -Fq "${release_download_url}/Quotari-${VERSION}.zip" "$appcast" ||
      die "appcast download URL is incorrect"
  fi

  if (( PUBLISH )); then
    log "publishing GitHub Release ${tag}"
    local release_arguments=(
      release create "$tag"
      "$dmg" "$zip" "$appcast"
      --repo "$REPOSITORY"
      --title "Quotari ${VERSION}"
      --target "$RELEASE_TARGET"
    )
    if [[ -n "$NOTES_FILE" ]]; then
      release_arguments+=(--notes-file "$NOTES_FILE")
    else
      release_arguments+=(--generate-notes)
    fi
    if (( DRAFT )); then
      release_arguments+=(--draft)
    fi
    run gh "${release_arguments[@]}"
  fi

  print -- "\nRelease artifacts:"
  print -- "  $dmg"
  print -- "  $zip"
  print -- "  $appcast"
  if (( PUBLISH && ! DRY_RUN )); then
    print -- "  https://github.com/${REPOSITORY}/releases/tag/${tag}"
  fi
}

parse_arguments "$@"

if [[ "$MODE" == "setup" ]]; then
  setup_release_credentials
else
  release_preflight
  create_release
fi
