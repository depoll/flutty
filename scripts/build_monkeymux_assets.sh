#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="$ROOT_DIR/remote/monkeymux"
ASSET_DIR="$ROOT_DIR/assets/monkeymux"
VERSION="$(sh "$REMOTE_DIR/monkeymux-version.sh" 2>/dev/null || echo "0.1.0")"

targets=(
  "darwin amd64 darwin-amd64"
  "darwin arm64 darwin-arm64"
  "linux amd64 linux-amd64"
  "linux arm64 linux-arm64"
)

mkdir -p "$ASSET_DIR/bin"

manifest_entries=()
for target in "${targets[@]}"; do
  read -r goos goarch platform <<<"$target"
  output_dir="$ASSET_DIR/bin/$platform"
  output="$output_dir/monkeymux"
  mkdir -p "$output_dir"
  (
    cd "$REMOTE_DIR"
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$output" .
  )
  size="$(wc -c <"$output" | tr -d ' ')"
  sha="$(shasum -a 256 "$output" | awk '{print $1}')"
  manifest_entries+=("$(printf '    {\"platform\":\"%s\",\"asset\":\"assets/monkeymux/bin/%s/monkeymux\",\"sha256\":\"%s\",\"size\":%s}' "$platform" "$platform" "$sha" "$size")")
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
