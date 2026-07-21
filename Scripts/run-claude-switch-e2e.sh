#!/bin/zsh

set -euo pipefail

usage() {
  print -u2 "Usage: $0 --target-id <saved-account-registry-id> --confirm-live-switch"
}

target=""
confirmed=0
while (( $# > 0 )); do
  case "$1" in
    --target-id)
      (( $# >= 2 )) || { usage; exit 2; }
      target="$2"
      shift 2
      ;;
    --confirm-live-switch)
      confirmed=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$target" && "$confirmed" == 1 ]] || { usage; exit 2; }

if [[ -n "${CI:-}" ]]; then
  print -u2 "The live Claude account-switch E2E test is disabled in CI."
  exit 1
fi

if pgrep -x Quotari >/dev/null; then
  print -u2 "Quit Quotari before running the live Claude account-switch E2E test."
  exit 1
fi

claude_path="$(command -v claude || true)"
if [[ -z "$claude_path" ]]; then
  print -u2 "Claude Code is not available on PATH."
  exit 1
fi

export QUOTARI_RUN_CLAUDE_SWITCH_E2E=1
export QUOTARI_E2E_CLAUDE_TARGET_ID="$target"
export QUOTARI_E2E_CLAUDE_PATH="$claude_path"

swift test --filter ClaudeAccountSwitchLiveE2ETests
