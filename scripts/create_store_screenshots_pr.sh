#!/usr/bin/env bash
# Compatibility wrapper: store screenshots are no longer committed.
# Publishes regenerated media to the rolling store-assets release / CI artifacts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

platform="both"
sync=false
generate="screenshots"

usage() {
  cat <<'USAGE'
Usage: scripts/create_store_screenshots_pr.sh [both|ios|android] [options]

Deprecated name kept for compatibility. Store screenshots are no longer
committed to git. This wrapper generates screenshots locally and publishes
them with scripts/store_assets.sh.

Options:
  --sync              Also trigger Sync Store Metadata after publishing
  --include-videos    Generate demo videos/App Previews too (generate=all)
  -h, --help          Show this help text

Prefer the new entry point directly:
  scripts/store_assets.sh publish --generate screenshots --platform both
  scripts/store_assets.sh publish --generate all --platform both --sync
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    both|ios|android) platform="$1" ;;
    --sync) sync=true ;;
    --include-videos) generate="all" ;;
    -h|--help) usage; exit 0 ;;
    --base|--branch|--draft)
      echo "warning: $1 is ignored; screenshots are published as CI assets, not PRs" >&2
      if [ "$1" != "--draft" ]; then
        shift || true
      fi
      ;;
    *)
      echo "error: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

args=(publish --generate "$generate" --platform "$platform")
if [ "$sync" = true ]; then
  args+=(--sync)
fi

exec "$ROOT_DIR/scripts/store_assets.sh" "${args[@]}"
