#!/usr/bin/env bash
# Prefetch sqlite3 hook binaries so Flutter native-asset builds do not fail
# on a single GitHub release-asset disconnect.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cache_sqlite3_native_assets.sh <target> [<target> ...]

Targets:
  linux-x64
  android-arm64
  android-x64
  android-arm
  android-ia32
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PACKAGE_CONFIG="${REPO_ROOT}/.dart_tool/package_config.json"
if [[ ! -f "$PACKAGE_CONFIG" ]]; then
  echo "package_config.json is missing; run flutter pub get first." >&2
  exit 1
fi

SQLITE3_ROOT="$(
  python3 - "$PACKAGE_CONFIG" <<'PY'
import json
import pathlib
import sys
import urllib.parse

package_config = pathlib.Path(sys.argv[1])
root_uri = next(
    package["rootUri"]
    for package in json.loads(package_config.read_text())["packages"]
    if package["name"] == "sqlite3"
)
print(pathlib.Path(urllib.parse.urlparse(root_uri).path))
PY
)"

ASSET_HASHES="${SQLITE3_ROOT}/lib/src/hook/asset_hashes.dart"
if [[ ! -f "$ASSET_HASHES" ]]; then
  echo "sqlite3 asset hashes not found at ${ASSET_HASHES}" >&2
  exit 1
fi

RELEASE_TAG="$(
  python3 - "$ASSET_HASHES" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"releaseTag = '([^']+)'", text)
if match is None:
    raise SystemExit("could not parse sqlite3 releaseTag")
print(match.group(1))
PY
)"

lookup_hash() {
  local filename="$1"
  python3 - "$ASSET_HASHES" "$filename" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
filename = sys.argv[2]
match = re.search(rf"'{re.escape(filename)}': '([0-9a-f]{{64}})'", text)
if match is None:
    raise SystemExit(f"unknown sqlite3 asset: {filename}")
print(match.group(1))
PY
}

prefetch() {
  local source_filename="$1"
  local dest_filename="$2"
  local sha256
  local dest_dir
  local dest_path
  local tmp_path
  local attempt

  sha256="$(lookup_hash "$source_filename")"
  dest_dir="${REPO_ROOT}/.dart_tool/hooks_runner/shared/sqlite3/build/download-${sha256:0:8}"
  dest_path="${dest_dir}/${dest_filename}"
  mkdir -p "$dest_dir"

  if [[ -f "$dest_path" ]]; then
    if echo "${sha256}  ${dest_path}" | shasum -a 256 -c --status; then
      echo "Reusing cached ${source_filename} as ${dest_filename}"
      return
    fi
    rm -f "$dest_path"
  fi

  tmp_path="${dest_path}.tmp"
  for attempt in 1 2 3 4 5; do
    if curl --fail --location \
      --retry 5 \
      --retry-all-errors \
      --retry-delay 2 \
      --output "$tmp_path" \
      "https://github.com/simolus3/sqlite3.dart/releases/download/${RELEASE_TAG}/${source_filename}"; then
      if echo "${sha256}  ${tmp_path}" | shasum -a 256 -c --status; then
        mv "$tmp_path" "$dest_path"
        echo "Cached ${source_filename} as ${dest_filename}"
        return
      fi
    fi
    rm -f "$tmp_path"
    echo "Retrying ${source_filename} (attempt ${attempt})" >&2
    sleep $((attempt * 2))
  done

  echo "Failed to download ${source_filename}" >&2
  exit 1
}

for target in "$@"; do
  case "$target" in
    linux-x64)
      prefetch libsqlite3.x64.linux.so libsqlite3.so
      ;;
    android-arm64)
      prefetch libsqlite3.arm64.android.so libsqlite3.so
      ;;
    android-x64)
      prefetch libsqlite3.x64.android.so libsqlite3.so
      ;;
    android-arm)
      prefetch libsqlite3.arm.android.so libsqlite3.so
      ;;
    android-ia32)
      prefetch libsqlite3.ia32.android.so libsqlite3.so
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown target: ${target}" >&2
      usage >&2
      exit 2
      ;;
  esac
done
