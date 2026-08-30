#!/usr/bin/env bash
# Publish an ad hoc signed IPA so it can be installed over the air.
#
# GitHub Actions artifacts always require an authenticated download, so they
# cannot back an itms-services install. This script instead splits the payload
# across two public HTTPS surfaces of this repository:
#
#   * the IPA is uploaded to a rolling prerelease (`ios-installs`), the same
#     pattern `scripts/store_assets.sh` uses for large binaries; and
#   * the manifest plist plus a small landing page are pushed to the
#     `ios-install-site` branch.
#
# Pages is configured with the GitHub Actions source, so a deployment replaces
# the whole site instead of appending to it. That branch is therefore the
# accumulated site state rather than the Pages source: this script commits into
# it (git's push rejection is what makes concurrent preview builds safe), and a
# separate workflow job publishes the branch to Pages.
#
# The landing page URL is what CI links from PR comments and deployments.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RELEASE_TAG="${IOS_INSTALL_RELEASE_TAG:-ios-installs}"
RELEASE_TITLE="${IOS_INSTALL_RELEASE_TITLE:-iOS ad hoc installs}"
PAGES_BRANCH="${IOS_INSTALL_PAGES_BRANCH:-ios-install-site}"
KEEP_BUILDS="${IOS_INSTALL_KEEP_BUILDS:-25}"

IPA_PATH=''
SLUG=''
BUNDLE_ID=''
TITLE=''
SUBTITLE=''
BUILD_NAME=''
BUILD_NUMBER=''
FLAVOR='private'
SOURCE_SHA=''
RUN_URL=''
STAGE_DIR=''

usage() {
  cat <<'EOF'
Usage: scripts/publish_ios_install.sh --ipa <path> --slug <slug> --bundle-id <id> \
         --title <title> --build-name <x.y.z> --build-number <n> [options]

Required:
  --ipa <path>           Ad hoc signed IPA to publish
  --slug <slug>          Stable install page key (e.g. pr-42 or private-1756)
  --bundle-id <id>       CFBundleIdentifier of the signed app
  --title <title>        Display name shown by iOS during install
  --build-name <x.y.z>   Marketing version
  --build-number <n>     Build number

Options:
  --subtitle <text>      Landing page subtitle (default: derived)
  --flavor <name>        private|production (default: private); selects the icon
  --source-sha <sha>     Commit the build came from
  --run-url <url>        Workflow run that produced the build
  --stage-dir <dir>      Keep the rendered manifest.plist / index.html here

Environment:
  GH_TOKEN                       Required; needs contents: write
  IOS_INSTALL_RELEASE_TAG        Rolling release tag (default: ios-installs)
  IOS_INSTALL_PAGES_BRANCH       Site state branch (default: ios-install-site)
  IOS_INSTALL_PAGES_BASE_URL     Override the derived https://<owner>.github.io/<repo> base
  IOS_INSTALL_KEEP_BUILDS        How many install pages / IPAs to retain (default: 25)

Outputs (appended to $GITHUB_OUTPUT when set, always printed):
  page-url, manifest-url, ipa-url
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ipa) IPA_PATH="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --subtitle) SUBTITLE="$2"; shift 2 ;;
    --build-name) BUILD_NAME="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --source-sha) SOURCE_SHA="$2"; shift 2 ;;
    --run-url) RUN_URL="$2"; shift 2 ;;
    --stage-dir) STAGE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

[ -n "$IPA_PATH" ] || fail '--ipa is required'
[ -f "$IPA_PATH" ] || fail "IPA not found at $IPA_PATH"
[ -n "$SLUG" ] || fail '--slug is required'
[ -n "$BUNDLE_ID" ] || fail '--bundle-id is required'
[ -n "$TITLE" ] || fail '--title is required'
[ -n "$BUILD_NAME" ] || fail '--build-name is required'
[ -n "$BUILD_NUMBER" ] || fail '--build-number is required'
[ -n "${GH_TOKEN:-}" ] || fail 'GH_TOKEN must be set'
command -v gh >/dev/null 2>&1 || fail "'gh' is required but was not found on PATH."

case "$SLUG" in
  *[!a-zA-Z0-9._-]*) fail "--slug may only contain [A-Za-z0-9._-]: $SLUG" ;;
esac

REPO_SLUG="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
REPO_OWNER="${REPO_SLUG%%/*}"
REPO_NAME="${REPO_SLUG##*/}"
OWNER_LOWER="$(printf '%s' "$REPO_OWNER" | tr '[:upper:]' '[:lower:]')"
REPO_LOWER="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')"

if [ -n "${IOS_INSTALL_PAGES_BASE_URL:-}" ]; then
  PAGES_BASE_URL="${IOS_INSTALL_PAGES_BASE_URL%/}"
elif [ "$REPO_LOWER" = "$OWNER_LOWER.github.io" ]; then
  PAGES_BASE_URL="https://$REPO_LOWER"
else
  PAGES_BASE_URL="https://$OWNER_LOWER.github.io/$REPO_NAME"
fi

ASSET_NAME="monkeyssh-$FLAVOR-$BUILD_NAME-$BUILD_NUMBER-adhoc.ipa"
IPA_URL="https://github.com/$REPO_SLUG/releases/download/$RELEASE_TAG/$ASSET_NAME"
PAGE_URL="$PAGES_BASE_URL/install/$SLUG/"
MANIFEST_URL="${PAGE_URL}manifest.plist"

case "$FLAVOR" in
  production) ICON_SOURCE='assets/icons/monkeyssh_icon.png' ;;
  *) ICON_SOURCE='assets/icons/monkeyssh_icon_private.png' ;;
esac
ICON_NAME="icon-$FLAVOR.png"
ICON_URL="$PAGES_BASE_URL/install/$ICON_NAME"

if [ -z "$SUBTITLE" ]; then
  SUBTITLE="$BUILD_NAME (build $BUILD_NUMBER)"
fi

# --- 1. Upload the IPA to the rolling prerelease -----------------------------

if ! gh release view "$RELEASE_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  gh release create "$RELEASE_TAG" \
    --repo "$REPO_SLUG" \
    --title "$RELEASE_TITLE" \
    --prerelease \
    --notes 'Ad hoc signed iOS builds published by CI for over-the-air installs. Only devices registered in the MonkeySSH Apple Developer account can run them.'
fi

STAGED_IPA="$(mktemp -d)/$ASSET_NAME"
cp "$IPA_PATH" "$STAGED_IPA"
gh release upload "$RELEASE_TAG" "$STAGED_IPA" --repo "$REPO_SLUG" --clobber

# --- 2. Render the manifest and landing page ---------------------------------

if [ -n "$STAGE_DIR" ]; then
  mkdir -p "$STAGE_DIR"
else
  STAGE_DIR="$(mktemp -d)"
fi
DETAIL_ARGS=()
DETAIL_ARGS+=(--detail "Version=<code>$BUILD_NAME</code>")
DETAIL_ARGS+=(--detail "Build=<code>$BUILD_NUMBER</code>")
DETAIL_ARGS+=(--detail "Bundle ID=<code>$BUNDLE_ID</code>")
if [ -n "$SOURCE_SHA" ]; then
  DETAIL_ARGS+=(--detail "Commit=<a href=\"https://github.com/$REPO_SLUG/commit/$SOURCE_SHA\"><code>${SOURCE_SHA:0:7}</code></a>")
fi
if [ -n "$RUN_URL" ]; then
  DETAIL_ARGS+=(--detail "Built by=<a href=\"$RUN_URL\">workflow run</a>")
fi

python3 scripts/generate_ios_install_manifest.py \
  --ipa-url "$IPA_URL" \
  --manifest-url "$MANIFEST_URL" \
  --bundle-id "$BUNDLE_ID" \
  --bundle-version "$BUILD_NAME" \
  --title "$TITLE" \
  --subtitle "$SUBTITLE" \
  --icon-url "$ICON_URL" \
  --output-manifest "$STAGE_DIR/manifest.plist" \
  --output-page "$STAGE_DIR/index.html" \
  "${DETAIL_ARGS[@]}"

# --- 3. Publish to the Pages branch ------------------------------------------

PAGES_DIR="$(mktemp -d)"
PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REMOTE_URL="https://x-access-token:$GH_TOKEN@github.com/$REPO_SLUG.git"

publish_pages() {
  rm -rf "$PAGES_DIR"
  mkdir -p "$PAGES_DIR"
  git -C "$PAGES_DIR" init -q
  git -C "$PAGES_DIR" config user.name 'github-actions[bot]'
  git -C "$PAGES_DIR" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
  git -C "$PAGES_DIR" remote add origin "$REMOTE_URL"

  if git -C "$PAGES_DIR" fetch --depth 1 origin "$PAGES_BRANCH" 2>/dev/null; then
    git -C "$PAGES_DIR" checkout -q -b "$PAGES_BRANCH" FETCH_HEAD
  else
    git -C "$PAGES_DIR" checkout -q --orphan "$PAGES_BRANCH"
  fi

  # actions/upload-pages-artifact does not run Jekyll, but keep .nojekyll so
  # the same content also works if the Pages source is ever switched back to
  # serving this branch directly.
  touch "$PAGES_DIR/.nojekyll"

  mkdir -p "$PAGES_DIR/install/$SLUG" || return 1
  cp "$STAGE_DIR/manifest.plist" "$PAGES_DIR/install/$SLUG/manifest.plist" || return 1
  cp "$STAGE_DIR/index.html" "$PAGES_DIR/install/$SLUG/index.html" || return 1
  cp "$ICON_SOURCE" "$PAGES_DIR/install/$ICON_NAME" || return 1

  INSTALL_ROOT="$PAGES_DIR/install" \
  ENTRY_SLUG="$SLUG" \
  ENTRY_TITLE="$TITLE" \
  ENTRY_SUBTITLE="$SUBTITLE" \
  ENTRY_PAGE_URL="$PAGE_URL" \
  ENTRY_IPA_ASSET="$ASSET_NAME" \
  ENTRY_PUBLISHED_AT="$PUBLISHED_AT" \
  ENTRY_KEEP="$KEEP_BUILDS" \
    python3 scripts/update_ios_install_index.py || return 1

  git -C "$PAGES_DIR" add -A || return 1
  if git -C "$PAGES_DIR" diff --cached --quiet; then
    echo 'No install page changes to publish.'
    return 0
  fi
  git -C "$PAGES_DIR" commit -q -m "Publish iOS install page for $SLUG ($BUILD_NAME+$BUILD_NUMBER)" || return 1
  git -C "$PAGES_DIR" push -q origin "HEAD:$PAGES_BRANCH" || return 1
}

# Preview builds for different PRs can land at the same time; each retry
# re-clones the branch tip so a losing push replays onto the winner.
PUSH_ATTEMPTS=8
for attempt in $(seq 1 "$PUSH_ATTEMPTS"); do
  if publish_pages; then
    break
  fi
  if [ "$attempt" -eq "$PUSH_ATTEMPTS" ]; then
    fail "could not publish the install page to $PAGES_BRANCH after $PUSH_ATTEMPTS attempts"
  fi
  echo "Publish attempt $attempt failed; retrying." >&2
  sleep $((attempt * 3))
done

# --- 4. Prune superseded IPAs ------------------------------------------------

RETAINED_ASSETS_FILE="$PAGES_DIR/install/retained-ipas.txt"
if [ -s "$RETAINED_ASSETS_FILE" ]; then
  ASSETS_JSON="$PAGES_DIR/release-assets.json"
  gh release view "$RELEASE_TAG" --repo "$REPO_SLUG" --json assets > "$ASSETS_JSON"
  while IFS= read -r stale_asset; do
    [ -n "$stale_asset" ] || continue
    echo "Removing superseded release asset $stale_asset"
    gh release delete-asset "$RELEASE_TAG" "$stale_asset" --repo "$REPO_SLUG" --yes || true
  done < <(python3 scripts/stale_ios_install_assets.py "$ASSETS_JSON" "$RETAINED_ASSETS_FILE")
fi

# --- 5. Report ---------------------------------------------------------------

echo "page-url=$PAGE_URL"
echo "manifest-url=$MANIFEST_URL"
echo "ipa-url=$IPA_URL"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "page-url=$PAGE_URL"
    echo "manifest-url=$MANIFEST_URL"
    echo "ipa-url=$IPA_URL"
  } >> "$GITHUB_OUTPUT"
fi
