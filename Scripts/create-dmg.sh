#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
background_path="${script_dir}/assets/dmg-background.png"
settings_path="${script_dir}/dmg-settings.py"
compatibility_bin_dir="${script_dir}/release-tools"
release_tools_dir="${RELEASE_TOOLS_DIR:-${project_dir}/.build/release-tools}"
dmgbuild_version="1.6.7"

usage() {
  cat <<'EOF'
Usage: create-dmg.sh <Quotari.app> [output.dmg]

Optional environment variables:
  DMGBUILD_BIN            Path to an existing dmgbuild executable
  PYTHON_BIN              Python 3.10+ used to install dmgbuild
  RELEASE_TOOLS_DIR       Directory for the managed dmgbuild environment
  CODESIGN_IDENTITY       Developer ID identity used to sign the DMG
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 64
fi

app_path="$1"
if [[ ! -d "${app_path}" ]]; then
  echo "App bundle does not exist: ${app_path}" >&2
  exit 1
fi

for asset in "${background_path}" "${script_dir}/assets/dmg-background@2x.png" "${settings_path}"; do
  if [[ ! -f "${asset}" ]]; then
    echo "Required DMG asset does not exist: ${asset}" >&2
    exit 1
  fi
done

if [[ ! -x "${compatibility_bin_dir}/sync" ]]; then
  echo "macOS sync compatibility wrapper is missing: ${compatibility_bin_dir}/sync" >&2
  exit 1
fi

dmgbuild_bin="${DMGBUILD_BIN:-}"
if [[ -z "${dmgbuild_bin}" ]] && command -v dmgbuild >/dev/null 2>&1; then
  dmgbuild_bin="$(command -v dmgbuild)"
fi

if [[ -z "${dmgbuild_bin}" ]]; then
  dmgbuild_bin="${release_tools_dir}/bin/dmgbuild"
  if [[ ! -x "${dmgbuild_bin}" ]]; then
    python_bin="${PYTHON_BIN:-python3}"
    command -v "${python_bin}" >/dev/null 2>&1 || {
      echo "Python 3.10 or newer is required to install dmgbuild." >&2
      exit 1
    }
    "${python_bin}" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' || {
      echo "dmgbuild ${dmgbuild_version} requires Python 3.10 or newer." >&2
      exit 1
    }
    "${python_bin}" -m venv "${release_tools_dir}"
    "${release_tools_dir}/bin/python" -m pip install --disable-pip-version-check \
      "dmgbuild==${dmgbuild_version}"
  fi
fi

app_path="$(cd "$(dirname "${app_path}")" && pwd)/$(basename "${app_path}")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_path}/Contents/Info.plist")"
output_path="${2:-$(dirname "${app_path}")/Quotari-${version}.dmg}"
output_dir="$(cd "$(dirname "${output_path}")" && pwd)"
output_path="${output_dir}/$(basename "${output_path}")"

rm -f "${output_path}"

PATH="${compatibility_bin_dir}:${PATH}" "${dmgbuild_bin}" \
  -s "${settings_path}" \
  -D "app=${app_path}" \
  -D "background=${background_path}" \
  "Quotari" \
  "${output_path}"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "${CODESIGN_IDENTITY}" "${output_path}"
fi

hdiutil verify "${output_path}"
echo "Created ${output_path}"
