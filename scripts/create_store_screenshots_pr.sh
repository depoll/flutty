#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/create_store_screenshots_pr.sh [both|ios|android] [options]

Generates fresh store screenshots locally, commits only screenshot PNG assets,
pushes a branch, and opens a pull request.

Options:
  --base <branch>     PR base branch and source ref. Default: main
  --branch <branch>   Branch to create. Default: chore/store-screenshots-<timestamp>
  --draft             Open the pull request as a draft
  -h, --help          Show this help text

Prerequisites:
  - macOS with Xcode simulators for iOS screenshots
  - a running Android emulator for Android screenshots
  - authenticated copilot, claude, and gh CLIs
  - Python Pillow available to python3
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required but was not found on PATH."
}

find_adb() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return
  fi
  for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    if [ -n "$sdk_root" ] && [ -x "$sdk_root/platform-tools/adb" ]; then
      printf '%s\n' "$sdk_root/platform-tools/adb"
      return
    fi
  done
  local home_adb="$HOME/Library/Android/sdk/platform-tools/adb"
  if [ -x "$home_adb" ]; then
    printf '%s\n' "$home_adb"
    return
  fi
  return 1
}

needs_android() {
  [ "$platform" = "android" ] || [ "$platform" = "both" ]
}

needs_ios() {
  [ "$platform" = "ios" ] || [ "$platform" = "both" ]
}

platform="both"
base_branch="${STORE_SCREENSHOT_PR_BASE:-main}"
branch_name="${STORE_SCREENSHOT_PR_BRANCH:-}"
draft=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    both|ios|android)
      platform="$1"
      ;;
    --base)
      shift
      [ "$#" -gt 0 ] || fail "--base requires a branch name."
      base_branch="$1"
      ;;
    --branch)
      shift
      [ "$#" -gt 0 ] || fail "--branch requires a branch name."
      branch_name="$1"
      ;;
    --draft)
      draft=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
  shift
done

timestamp="$(date -u +%Y%m%d-%H%M%S)"
if [ -z "$branch_name" ]; then
  branch_name="chore/store-screenshots-$timestamp"
fi

require_command git
require_command gh
require_command flutter
require_command python3
require_command copilot
require_command claude

if needs_ios; then
  require_command xcrun
fi

if needs_android; then
  adb_path="$(find_adb)" || fail "adb is required for Android screenshots."
  if ! "$adb_path" devices | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit found ? 0 : 1 }'; then
    fail "No running Android device or emulator found. Start one before running Android screenshots."
  fi
fi

if ! python3 - <<'PY' >/dev/null 2>&1
from PIL import Image
PY
then
  fail "Python Pillow is required. Install it with: python3 -m pip install Pillow"
fi

repo_root="$(git rev-parse --show-toplevel)"
repo_parent="$(dirname "$repo_root")"
repo_parent_name="$(basename "$repo_parent")"
if [[ "$repo_parent_name" == *.worktrees ]]; then
  worktrees_dir="$repo_parent"
else
  worktrees_dir="$repo_parent/$(basename "$repo_root").worktrees"
fi

branch_slug="$(printf '%s' "$branch_name" | sed 's#[/:]#-#g')"
worktree_dir="$worktrees_dir/$branch_slug"

if git show-ref --verify --quiet "refs/heads/$branch_name"; then
  fail "Local branch already exists: $branch_name"
fi
if git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
  fail "Remote branch already exists: origin/$branch_name"
fi
if [ -e "$worktree_dir" ]; then
  fail "Worktree path already exists: $worktree_dir"
fi

echo "Fetching origin/$base_branch..."
git -C "$repo_root" fetch --no-tags origin "$base_branch"

mkdir -p "$worktrees_dir"
echo "Creating worktree $worktree_dir on $branch_name..."
git -C "$repo_root" worktree add -b "$branch_name" "$worktree_dir" "origin/$base_branch"

(
  cd "$worktree_dir"

  echo "Installing Flutter dependencies..."
  flutter pub get

  echo "Generating $platform store screenshots..."
  python3 scripts/generate_store_screenshots.py "$platform"

  echo "Validating generated screenshots..."
  python3 scripts/validate_store_screenshots.py "$platform"

  screenshot_paths=()
  if needs_ios; then
    screenshot_paths+=('ios/fastlane/screenshots/en-US/*.png')
  fi
  if needs_android; then
    screenshot_paths+=(
      'android/fastlane/metadata-production/android/en-US/images/*Screenshots/*.png'
      'android/fastlane/metadata-private/android/en-US/images/*Screenshots/*.png'
    )
  fi

  git add -- "${screenshot_paths[@]}"
  if git diff --cached --quiet; then
    echo "No screenshot changes were generated; no pull request opened."
    exit 0
  fi

  git commit -m "chore: update store screenshots" \
    -m "Generated locally with scripts/generate_store_screenshots.py $platform."

  echo "Pushing $branch_name..."
  git push -u origin "$branch_name"

  body_file="$(mktemp)"
  cat >"$body_file" <<EOF
## Summary

- Regenerates $platform store screenshots from the local screenshot harness.
- Validates generated screenshot dimensions and store-safety checks.

## Validation

- \`python3 scripts/generate_store_screenshots.py $platform\`
- \`python3 scripts/validate_store_screenshots.py $platform\`
EOF

  pr_args=(
    --base "$base_branch"
    --head "$branch_name"
    --title "chore: update store screenshots"
    --body-file "$body_file"
  )
  if [ "$draft" = true ]; then
    pr_args+=(--draft)
  fi

  gh pr create "${pr_args[@]}"
  rm -f "$body_file"

  if [ -n "$(git status --short --untracked-files=no)" ]; then
    echo
    echo "Non-screenshot files changed in $worktree_dir and were left unstaged:"
    git status --short --untracked-files=no
  fi
)

echo
echo "Screenshot PR workflow complete."
echo "Worktree: $worktree_dir"
