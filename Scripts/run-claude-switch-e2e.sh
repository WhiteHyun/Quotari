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

lock_directory="/tmp/com.whitehyun.Quotari.ClaudeSwitchE2E.${EUID}.lock"
if ! mkdir "$lock_directory" 2>/dev/null; then
  print -u2 "Another live Claude account-switch E2E test is already running."
  exit 1
fi
release_lock() {
  rmdir "$lock_directory" 2>/dev/null || true
}
trap release_lock EXIT

interrupted=0
record_interruption() {
  if (( interrupted == 0 )); then
    print -u2 "Interrupt received; waiting for Claude credential restoration to finish."
  fi
  interrupted=1
}

if pgrep -x Quotari >/dev/null; then
  print -u2 "Quit Quotari before running the live Claude account-switch E2E test."
  exit 1
fi

claude_path="$(command -v claude || true)"
if [[ -z "$claude_path" ]]; then
  print -u2 "Claude Code is not available on PATH."
  exit 1
fi
swift_path="$(command -v swift || true)"
python_path="$(command -v python3 || true)"
if [[ -z "$swift_path" || -z "$python_path" ]]; then
  print -u2 "Swift and Python 3 are required to run the live E2E test safely."
  exit 1
fi

export QUOTARI_RUN_CLAUDE_SWITCH_E2E=1
export QUOTARI_E2E_CLAUDE_TARGET_ID="$target"
export QUOTARI_E2E_CLAUDE_PATH="$claude_path"

# The test owns restoration once it starts mutating the shared credential slot.
# Keep it alive across terminal/process signals, while the runner records the
# interruption and holds the machine lock until restoration has completed.
trap '' HUP INT TERM
"$python_path" -c \
  'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
  "$swift_path" test --filter ClaudeAccountSwitchLiveE2ETests &
test_pid=$!
trap record_interruption HUP INT TERM

test_status=0
while true; do
  if wait "$test_pid"; then
    test_status=0
    break
  else
    test_status=$?
  fi

  if (( interrupted == 0 )) || ! kill -0 "$test_pid" 2>/dev/null; then
    break
  fi
done

if (( interrupted )); then
  exit 130
fi
exit "$test_status"
