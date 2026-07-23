#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CATALOG="$ROOT/Sources/Quotari/Resources/Localizable.xcstrings"
OUTPUT=$(mktemp -d "${TMPDIR:-/tmp}/quotari-localizations.XXXXXX")
trap 'rm -rf "$OUTPUT"' EXIT

xcrun xcstringstool compile \
  "$CATALOG" \
  --output-directory "$OUTPUT" \
  --serialization-format text

COMPILED="$OUTPUT/ko.lproj/Localizable.strings"
if [[ ! -s "$COMPILED" ]]; then
  echo "String catalog did not compile a Korean localization." >&2
  exit 1
fi

plutil -lint "$COMPILED" >/dev/null
