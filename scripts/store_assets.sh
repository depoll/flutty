#!/usr/bin/env bash
# Manage regenerated store media outside git.
#
# Store screenshots, App Preview videos, and demo videos are large binary
# deliverables produced by local generators. They are published to a rolling
# GitHub Release tag (store-assets) and re-hosted as GitHub Actions artifacts
# during publish/sync workflows instead of being committed to the repository.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RELEASE_TAG="${STORE_ASSETS_RELEASE_TAG:-store-assets}"
RELEASE_TITLE="${STORE_ASSETS_RELEASE_TITLE:-Store assets}"
ASSET_NAME="${STORE_ASSETS_ARCHIVE_NAME:-store-assets.tar.gz}"
DEFAULT_OUTPUT="${STORE_ASSETS_ARCHIVE:-$ROOT_DIR/build/store-assets/$ASSET_NAME}"

usage() {
  cat <<'EOF'
Usage: scripts/store_assets.sh <command> [options]

Commands:
  paths                 Print tracked regenerated store-media paths
  package [options]     Create a tar.gz of local regenerated store media
  download [options]    Download + extract the latest published store assets
  publish [options]     Package local media, upload to the store-assets release,
                        and optionally validate / trigger metadata sync
  present               Exit 0 if required store media exists locally

package options:
  -o, --output <path>   Archive path (default: build/store-assets/store-assets.tar.gz)
  --require-screenshots Fail if screenshot sets are incomplete
  --require-videos      Fail if demo/app-preview videos are incomplete

download options:
  -o, --output <dir>    Directory to extract into (default: repo root)
  --repo <owner/repo>   GitHub repo (default: current gh repo)
  --tag <tag>           Release tag (default: store-assets)
  --archive <path>      Use a local archive instead of downloading
  --run-id <id>         Download the store-assets artifact from a workflow run

publish options:
  --generate <target>   Generate before packaging: none|screenshots|videos|all
                        (default: none). screenshots/videos/all accept
                        ios|android|both via --platform.
  --platform <target>   ios|android|both (default: both); used with --generate
  --skip-validate       Skip local validators before upload
  --sync                Trigger Sync Store Metadata after publishing
  --app <target>        private|production|both when --sync (default: both)
  --no-workflow         Do not dispatch publish-store-assets.yml
  -o, --output <path>   Archive path to build/upload

Environment:
  STORE_ASSETS_RELEASE_TAG   Override release tag (default: store-assets)
  STORE_ASSETS_ARCHIVE_NAME  Override archive file name
  GH_TOKEN / gh auth         Required for download/publish against GitHub
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but was not found on PATH."
}

repo_slug() {
  if [ -n "${STORE_ASSETS_REPO:-}" ]; then
    printf '%s\n' "$STORE_ASSETS_REPO"
    return
  fi
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '%s\n' "$GITHUB_REPOSITORY"
    return
  fi
  require_command gh
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

screenshot_globs() {
  cat <<'EOF'
ios/fastlane/screenshots/en-US/*.png
android/fastlane/metadata-production/android/en-US/images/phoneScreenshots/*.png
android/fastlane/metadata-production/android/en-US/images/sevenInchScreenshots/*.png
android/fastlane/metadata-production/android/en-US/images/tenInchScreenshots/*.png
android/fastlane/metadata-private/android/en-US/images/phoneScreenshots/*.png
android/fastlane/metadata-private/android/en-US/images/sevenInchScreenshots/*.png
android/fastlane/metadata-private/android/en-US/images/tenInchScreenshots/*.png
EOF
}

video_globs() {
  cat <<'EOF'
ios/fastlane/app-previews/en-US/*.mov
ios/fastlane/app-previews/en-US/*.mp4
ios/fastlane/app-previews/en-US/*.m4v
store/demo-videos/google-play/*.mp4
store/demo-videos/ads/*.mp4
EOF
}

all_globs() {
  screenshot_globs
  video_globs
}

expand_existing() {
  local pattern
  local path
  local matches=0
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    shopt -s nullglob
    # shellcheck disable=SC2086
    for path in $pattern; do
      if [ -f "$path" ]; then
        printf '%s\n' "$path"
        matches=$((matches + 1))
      fi
    done
    shopt -u nullglob
  done
  return 0
}

list_media_files() {
  all_globs | expand_existing | sort -u
}

count_media_files() {
  list_media_files | wc -l | tr -d ' '
}

assert_screenshots_present() {
  require_command python3
  python3 scripts/validate_store_screenshots.py both >/dev/null
}

assert_videos_present() {
  require_command python3
  python3 scripts/validate_store_demo_videos.py all >/dev/null
}

cmd_paths() {
  all_globs
}

cmd_present() {
  local count
  count="$(count_media_files)"
  if [ "$count" -eq 0 ]; then
    echo "No regenerated store media found in the working tree."
    return 1
  fi
  echo "Found $count regenerated store media file(s)."
  list_media_files
}

write_manifest() {
  local archive_path="$1"
  local manifest_path="$2"
  local file_count
  file_count="$(count_media_files)"
  require_command python3
  python3 - "$archive_path" "$manifest_path" "$file_count" "$RELEASE_TAG" <<'PY'
import hashlib
import json
import os
import sys
import time
from pathlib import Path

archive_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
file_count = int(sys.argv[3])
release_tag = sys.argv[4]
root = Path.cwd()

files = []
for line in os.popen('scripts/store_assets.sh paths'):
    pattern = line.strip()
    if not pattern:
        continue
    for path in sorted(root.glob(pattern)):
        if not path.is_file():
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rel = path.relative_to(root).as_posix()
        files.append({
            'path': rel,
            'sha256': digest,
            'size': path.stat().st_size,
        })

payload = {
    'version': 1,
    'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'release_tag': release_tag,
    'archive': archive_path.name,
    'file_count': len(files),
    'files': files,
}
if file_count != len(files):
    # paths may include unmatched globs; prefer discovered files.
    payload['file_count'] = len(files)
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
print(f'Wrote manifest with {len(files)} file(s) to {manifest_path}')
PY
}

cmd_package() {
  local output="$DEFAULT_OUTPUT"
  local require_screenshots=false
  local require_videos=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--output)
        shift
        [ "$#" -gt 0 ] || fail "--output requires a path"
        output="$1"
        ;;
      --require-screenshots)
        require_screenshots=true
        ;;
      --require-videos)
        require_videos=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown package option: $1"
        ;;
    esac
    shift
  done

  require_command tar
  require_command gzip

  if [ "$(count_media_files)" -eq 0 ]; then
    fail "No regenerated store media found to package. Generate screenshots/videos first."
  fi

  if [ "$require_screenshots" = true ]; then
    assert_screenshots_present
  fi
  if [ "$require_videos" = true ]; then
    assert_videos_present
  fi

  mkdir -p "$(dirname "$output")"
  local staging
  staging="$(mktemp -d)"
  # Expand the path when registering the trap so nounset cleanup is safe.
  # shellcheck disable=SC2064
  trap "rm -rf $(printf %q "$staging")" RETURN

  local path
  while IFS= read -r path; do
    mkdir -p "$staging/$(dirname "$path")"
    cp "$path" "$staging/$path"
  done < <(list_media_files)

  write_manifest "$output" "$staging/store-assets-manifest.json"

  tar -C "$staging" -czf "$output" .
  local size
  size="$(wc -c <"$output" | tr -d ' ')"
  echo "Packaged store assets -> $output ($size bytes)"
}

extract_archive() {
  local archive="$1"
  local dest="$2"
  mkdir -p "$dest"
  tar -C "$dest" -xzf "$archive"
}

cmd_download() {
  local dest="$ROOT_DIR"
  local repo=""
  local tag="$RELEASE_TAG"
  local archive=""
  local run_id=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--output)
        shift
        [ "$#" -gt 0 ] || fail "--output requires a directory"
        dest="$1"
        ;;
      --repo)
        shift
        [ "$#" -gt 0 ] || fail "--repo requires owner/name"
        repo="$1"
        ;;
      --tag)
        shift
        [ "$#" -gt 0 ] || fail "--tag requires a release tag"
        tag="$1"
        ;;
      --archive)
        shift
        [ "$#" -gt 0 ] || fail "--archive requires a path"
        archive="$1"
        ;;
      --run-id)
        shift
        [ "$#" -gt 0 ] || fail "--run-id requires a workflow run id"
        run_id="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown download option: $1"
        ;;
    esac
    shift
  done

  require_command tar
  mkdir -p "$dest"

  if [ -n "$archive" ]; then
    [ -f "$archive" ] || fail "Archive not found: $archive"
    extract_archive "$archive" "$dest"
    echo "Extracted $archive into $dest"
    return 0
  fi

  require_command gh
  repo="${repo:-$(repo_slug)}"

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf $(printf %q "$tmp")" RETURN

  if [ -n "$run_id" ]; then
    echo "Downloading store-assets artifact from run $run_id ($repo)..."
    gh run download "$run_id" \
      --repo "$repo" \
      --name store-assets \
      --dir "$tmp"
    if [ -f "$tmp/$ASSET_NAME" ]; then
      extract_archive "$tmp/$ASSET_NAME" "$dest"
    elif [ -f "$tmp/store-assets/$ASSET_NAME" ]; then
      extract_archive "$tmp/store-assets/$ASSET_NAME" "$dest"
    else
      # Artifact may already be the extracted tree.
      if [ -d "$tmp/ios" ] || [ -d "$tmp/store" ] || [ -d "$tmp/android" ]; then
        cp -R "$tmp"/. "$dest"/
      else
        fail "Could not find store assets inside workflow artifact for run $run_id"
      fi
    fi
    echo "Restored store assets from workflow run $run_id into $dest"
    return 0
  fi

  echo "Downloading $ASSET_NAME from release $tag ($repo)..."
  if ! gh release download "$tag" \
    --repo "$repo" \
    --pattern "$ASSET_NAME" \
    --dir "$tmp" \
    --clobber; then
    fail "Failed to download $ASSET_NAME from release '$tag'. Publish store assets first with scripts/store_assets.sh publish"
  fi
  extract_archive "$tmp/$ASSET_NAME" "$dest"
  echo "Restored store assets from release $tag into $dest"
}

cmd_publish() {
  local output="$DEFAULT_OUTPUT"
  local generate="none"
  local platform="both"
  local skip_validate=false
  local sync=false
  local app="both"
  local dispatch_workflow=true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--output)
        shift
        [ "$#" -gt 0 ] || fail "--output requires a path"
        output="$1"
        ;;
      --generate)
        shift
        [ "$#" -gt 0 ] || fail "--generate requires none|screenshots|videos|all"
        generate="$1"
        ;;
      --platform)
        shift
        [ "$#" -gt 0 ] || fail "--platform requires ios|android|both"
        platform="$1"
        ;;
      --skip-validate)
        skip_validate=true
        ;;
      --sync)
        sync=true
        ;;
      --app)
        shift
        [ "$#" -gt 0 ] || fail "--app requires private|production|both"
        app="$1"
        ;;
      --no-workflow)
        dispatch_workflow=false
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown publish option: $1"
        ;;
    esac
    shift
  done

  require_command gh
  require_command python3

  case "$generate" in
    none) ;;
    screenshots)
      python3 scripts/generate_store_screenshots.py "$platform"
      ;;
    videos)
      python3 scripts/generate_store_demo_videos.py "$platform"
      ;;
    all)
      python3 scripts/generate_store_screenshots.py "$platform"
      python3 scripts/generate_store_demo_videos.py "$platform"
      ;;
    *)
      fail "--generate must be one of: none, screenshots, videos, all"
      ;;
  esac

  local package_args=()
  if [ "$skip_validate" = false ]; then
    # Validate whatever is present; require screenshots always for publish.
    package_args+=(--require-screenshots)
    if all_globs | expand_existing | grep -E '\.(mov|mp4|m4v)$' >/dev/null 2>&1; then
      package_args+=(--require-videos)
    fi
  fi
  cmd_package -o "$output" "${package_args[@]+"${package_args[@]}"}"

  local repo
  repo="$(repo_slug)"
  local notes
  notes="$(mktemp)"
  cat >"$notes" <<EOF
Rolling archive of regenerated MonkeySSH store media (screenshots, App Previews, demo videos).

- Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Source commit: $(git rev-parse HEAD)
- Do not commit these binaries to git; download with \`scripts/store_assets.sh download\`.
EOF

  if gh release view "$RELEASE_TAG" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$RELEASE_TAG" "$output" \
      --repo "$repo" \
      --clobber
    gh release edit "$RELEASE_TAG" \
      --repo "$repo" \
      --title "$RELEASE_TITLE" \
      --notes-file "$notes" \
      --prerelease \
      --latest=false >/dev/null
  else
    gh release create "$RELEASE_TAG" "$output" \
      --repo "$repo" \
      --title "$RELEASE_TITLE" \
      --notes-file "$notes" \
      --prerelease \
      --latest=false
  fi
  rm -f "$notes"
  echo "Published $output to release $RELEASE_TAG on $repo"

  if [ "$dispatch_workflow" = true ]; then
    local -a workflow_args=(
      publish-store-assets.yml
      --repo "$repo"
      -f "sync=$( [ "$sync" = true ] && echo true || echo false )"
      -f "app=$app"
      -f "platform=both"
    )
    if gh workflow run "${workflow_args[@]}"; then
      echo "Dispatched publish-store-assets.yml"
    else
      echo "warning: failed to dispatch publish-store-assets.yml" >&2
    fi
  elif [ "$sync" = true ]; then
    gh workflow run sync-metadata.yml \
      --repo "$repo" \
      -f "platform=both" \
      -f "app=$app"
    echo "Dispatched sync-metadata.yml"
  fi
}

main() {
  local command="${1:-}"
  if [ -z "$command" ]; then
    usage
    exit 1
  fi
  shift || true
  case "$command" in
    paths) cmd_paths "$@" ;;
    present) cmd_present "$@" ;;
    package) cmd_package "$@" ;;
    download) cmd_download "$@" ;;
    publish) cmd_publish "$@" ;;
    -h|--help|help) usage ;;
    *)
      usage >&2
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"
