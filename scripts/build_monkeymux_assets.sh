#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="$ROOT_DIR/remote/monkeymux"
ASSET_DIR="$ROOT_DIR/assets/monkeymux"
VERSION="$(sh "$REMOTE_DIR/monkeymux-version.sh" 2>/dev/null || echo "0.1.0")"
STAMP_FILE="$ASSET_DIR/.build-inputs.sha256"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

force=false
case "${1:-}" in
  "") ;;
  --force) force=true ;;
  *)
    echo "usage: $0 [--force]" >&2
    exit 2
    ;;
esac

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

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return
  fi
  echo "sha256sum or shasum is required" >&2
  return 1
}

GO_TOOLCHAIN="$(awk '$1 == "toolchain" { print $2; exit }' "$REMOTE_DIR/go.mod")"
if [[ ! "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "remote/monkeymux/go.mod must pin an exact Go toolchain" >&2
  exit 1
fi

build_fingerprint() {
  {
    printf 'toolchain=%s\n' "$GO_TOOLCHAIN"
    find "$REMOTE_DIR" -type f \
      \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \
         -o -name 'monkeymux-version.sh' -o -path '*/conpty/*' \) \
      -print | LC_ALL=C sort | while IFS= read -r input; do
        printf '%s  %s\n' \
          "$(sha256_file "$input")" "${input#"$ROOT_DIR/"}"
      done
    printf '%s  scripts/build_monkeymux_assets.sh\n' \
      "$(sha256_file "$ROOT_DIR/scripts/build_monkeymux_assets.sh")"
  } | sha256_stdin
}

assets_are_complete() {
  [[ -s "$ASSET_DIR/manifest.json" ]] || return 1
  local target platform
  for target in "${targets[@]}"; do
    read -r _ _ platform <<<"$target"
    [[ -s "$ASSET_DIR/bin/$platform/monkeymux.gz" ]] || return 1
  done
}

fingerprint="$(build_fingerprint)"
stored_fingerprint=""
if [[ -f "$STAMP_FILE" ]]; then
  stored_fingerprint="$(<"$STAMP_FILE")"
fi
if [[ "$force" == false ]] && assets_are_complete && \
   [[ "$stored_fingerprint" == "$fingerprint" ]]; then
  echo "MonkeyMux assets are current ($VERSION)."
  exit 0
fi

rm -f "$STAMP_FILE"
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
    GOTOOLCHAIN="$GO_TOOLCHAIN" GOOS="$goos" GOARCH="$goarch" \
      CGO_ENABLED=0 go build -buildvcs=false -trimpath \
      -ldflags="-s -w" -o "$raw_output" .
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

printf '%s\n' "$fingerprint" > "$STAMP_FILE"
echo "Built MonkeyMux $VERSION assets with $GO_TOOLCHAIN."
