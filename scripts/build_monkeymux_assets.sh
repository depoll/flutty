#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="$ROOT_DIR/remote/monkeymux"
ASSET_DIR="$ROOT_DIR/assets/monkeymux"
VERSION="$(sh "$REMOTE_DIR/monkeymux-version.sh" 2>/dev/null || echo "0.1.0")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

targets=(
  "darwin amd64 darwin-amd64"
  "darwin arm64 darwin-arm64"
  "linux amd64 linux-amd64"
  "linux arm64 linux-arm64"
  "windows amd64 windows-amd64"
  "windows arm64 windows-arm64"
)

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  echo "sha256sum or shasum is required" >&2
  return 1
}

rm -rf "$ASSET_DIR/bin"
mkdir -p "$ASSET_DIR/bin"

manifest_entries=()
for target in "${targets[@]}"; do
  read -r goos goarch platform <<<"$target"
  output_dir="$ASSET_DIR/bin/$platform"
  raw_output="$TMP_DIR/$platform/monkeymux"
  output="$output_dir/monkeymux.gz"
  mkdir -p "$output_dir"
  mkdir -p "$(dirname "$raw_output")"
  (
    cd "$REMOTE_DIR"
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$raw_output" .
  )
  gzip -n -c "$raw_output" > "$output"
  size="$(wc -c <"$raw_output" | tr -d ' ')"
  sha="$(sha256_file "$raw_output")"
  manifest_entries+=("$(printf '    {\"platform\":\"%s\",\"asset\":\"assets/monkeymux/bin/%s/monkeymux.gz\",\"encoding\":\"gzip\",\"sha256\":\"%s\",\"size\":%s}' "$platform" "$platform" "$sha" "$size")")
done

{
  printf '{\n'
  printf '  "version": "%s",\n' "$VERSION"
  printf '  "entries": [\n'
  for i in "${!manifest_entries[@]}"; do
    if [ "$i" -gt 0 ]; then
      printf ',\n'
    fi
    printf '%s' "${manifest_entries[$i]}"
  done
  printf '\n  ]\n'
  printf '}\n'
} > "$ASSET_DIR/manifest.json"
