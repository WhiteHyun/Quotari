#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CATALOG="$ROOT/Sources/Quotari/Resources/Localizable.xcstrings"
COMPILED="$ROOT/Sources/Quotari/Resources/ko.lproj/Localizable.strings"
OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/quotari-localizations.XXXXXX")
trap 'rm -rf "$OUTPUT"' EXIT

xcrun xcstringstool compile \
  "$CATALOG" \
  --output-directory "$OUTPUT" \
  --serialization-format text

if ! cmp -s "$OUTPUT/ko.lproj/Localizable.strings" "$COMPILED"; then
  echo "Compiled Korean localization is out of date." >&2
  echo "Run: xcrun xcstringstool compile Sources/Quotari/Resources/Localizable.xcstrings --output-directory Sources/Quotari/Resources --serialization-format text" >&2
  exit 1
fi
