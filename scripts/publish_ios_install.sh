#!/usr/bin/env bash
# Publish an ad hoc signed IPA so it can be installed over the air.
#
# GitHub Actions artifacts always require an authenticated download, so they
# cannot back an itms-services install. Each build therefore gets its own
# public prerelease -- `ios-install-pr-<n>` for a pull request,
# `ios-install-main` for a Deploy Private build -- holding the IPA and the
# metadata needed to render its install page.
#
# Those releases are the source of truth. `scripts/generate_ios_install_site.py`
# regenerates the whole GitHub Pages site from them, so nothing here has to
# track site state, and deleting a release is all it takes to retire a build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IPA_PATH=''
SLUG=''
TAG=''
BUNDLE_ID=''
TITLE=''
SUBTITLE=''
BUILD_NAME=''
BUILD_NUMBER=''
FLAVOR='private'
SOURCE_SHA=''
RUN_URL=''
PR_NUMBER=''
STAGE_DIR=''

usage() {
  cat <<'EOF'
Usage: scripts/publish_ios_install.sh --ipa <path> --slug <slug> --tag <tag> \
         --bundle-id <id> --title <title> --build-name <x.y.z> \
         --build-number <n> --source-sha <sha> [options]

Required:
  --ipa <path>           Ad hoc signed IPA to publish
  --slug <slug>          Install page directory (e.g. pr-42 or main)
  --tag <tag>            Release tag holding this build (e.g. ios-install-pr-42)
  --bundle-id <id>       CFBundleIdentifier of the signed app
  --title <title>        Display name shown by iOS during install
  --build-name <x.y.z>   Marketing version
  --build-number <n>     Build number
  --source-sha <sha>     Commit the build came from

Options:
  --subtitle <text>      Install page subtitle (default: derived)
  --flavor <name>        private|production (default: private); selects the icon
  --pr-number <n>        Pull request this build belongs to
  --run-url <url>        Workflow run that produced the build
  --stage-dir <dir>      Also write manifest.plist / index.html here

Environment:
  GH_TOKEN                       Required; needs contents: write
  IOS_INSTALL_PAGES_BASE_URL     Override the derived https://<owner>.github.io/<repo> base

Outputs (appended to $GITHUB_OUTPUT when set, always printed):
  page-url, manifest-url, ipa-url, tag
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
    --tag) TAG="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --subtitle) SUBTITLE="$2"; shift 2 ;;
    --build-name) BUILD_NAME="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    --source-sha) SOURCE_SHA="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --run-url) RUN_URL="$2"; shift 2 ;;
    --stage-dir) STAGE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

[ -n "$IPA_PATH" ] || fail '--ipa is required'
[ -f "$IPA_PATH" ] || fail "IPA not found at $IPA_PATH"
[ -n "$SLUG" ] || fail '--slug is required'
[ -n "$TAG" ] || fail '--tag is required'
[ -n "$BUNDLE_ID" ] || fail '--bundle-id is required'
[ -n "$TITLE" ] || fail '--title is required'
[ -n "$BUILD_NAME" ] || fail '--build-name is required'
[ -n "$BUILD_NUMBER" ] || fail '--build-number is required'
[ -n "$SOURCE_SHA" ] || fail '--source-sha is required'
[ -n "${GH_TOKEN:-}" ] || fail 'GH_TOKEN must be set'
command -v gh >/dev/null 2>&1 || fail "'gh' is required but was not found on PATH."

case "$SLUG" in
  *[!a-zA-Z0-9._-]* ) fail "--slug may only contain [A-Za-z0-9._-]: $SLUG" ;;
esac
case "$SOURCE_SHA" in
  *[!0-9a-fA-F]* | '') fail "--source-sha must be a hex commit SHA: $SOURCE_SHA" ;;
esac
# scripts/generate_ios_install_site.py selects releases by this prefix, and
# .github/workflows/release.yml only treats v* tags as app releases.
case "$TAG" in
  ios-install-*) ;;
  *) fail "--tag must start with ios-install-: $TAG" ;;
esac

REPO_SLUG="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

PAGES_BASE_URL="$(
  IOS_INSTALL_PAGES_BASE_URL="${IOS_INSTALL_PAGES_BASE_URL:-}" \
  REPO_SLUG="$REPO_SLUG" python3 scripts/ios_install_pages_url.py
)"

ASSET_NAME="monkeyssh-$FLAVOR-$BUILD_NAME-$BUILD_NUMBER-${SOURCE_SHA:0:7}-adhoc.ipa"
IPA_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/$ASSET_NAME"
PAGE_URL="$PAGES_BASE_URL/install/$SLUG/"
MANIFEST_URL="${PAGE_URL}manifest.plist"
ICON_URL="$PAGES_BASE_URL/install/icon-$FLAVOR.png"

if [ -z "$SUBTITLE" ]; then
  SUBTITLE="$BUILD_NAME (build $BUILD_NUMBER)"
fi

# --- 1. Describe the build in the release body -------------------------------
#
# generate_ios_install_site.py reads this back out of a single paginated
# releases API call, so regenerating the site needs no asset downloads.

RELEASE_BODY_FILE="$(mktemp)"
SLUG="$SLUG" TAG="$TAG" TITLE="$TITLE" SUBTITLE="$SUBTITLE" BUNDLE_ID="$BUNDLE_ID" \
BUILD_NAME="$BUILD_NAME" BUILD_NUMBER="$BUILD_NUMBER" FLAVOR="$FLAVOR" \
SOURCE_SHA="$SOURCE_SHA" IPA_ASSET="$ASSET_NAME" RUN_URL="$RUN_URL" \
PR_NUMBER="$PR_NUMBER" REPO_SLUG="$REPO_SLUG" \
  python3 scripts/ios_install_release_body.py > "$RELEASE_BODY_FILE"

RELEASE_TITLE="MonkeySSH iOS install"
if [ -n "$PR_NUMBER" ]; then
  RELEASE_TITLE="$RELEASE_TITLE — PR #$PR_NUMBER"
else
  RELEASE_TITLE="$RELEASE_TITLE — $BUILD_NAME"
fi

if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  gh release edit "$TAG" --repo "$REPO_SLUG" \
    --title "$RELEASE_TITLE" --notes-file "$RELEASE_BODY_FILE" --prerelease
else
  gh release create "$TAG" --repo "$REPO_SLUG" \
    --title "$RELEASE_TITLE" --notes-file "$RELEASE_BODY_FILE" --prerelease \
    --target "$SOURCE_SHA"
fi

# --- 2. Upload the IPA, retiring the build this one replaces -----------------

STAGED_IPA="$(mktemp -d)/$ASSET_NAME"
cp "$IPA_PATH" "$STAGED_IPA"
gh release upload "$TAG" "$STAGED_IPA" --repo "$REPO_SLUG" --clobber

# Each release holds exactly one build, so an IPA under a different name is
# left over from a superseded commit of the same PR.
while IFS= read -r existing; do
  [ -n "$existing" ] || continue
  [ "$existing" != "$ASSET_NAME" ] || continue
  case "$existing" in
    *.ipa) ;;
    *) continue ;;
  esac
  echo "Removing superseded IPA $existing from $TAG"
  gh release delete-asset "$TAG" "$existing" --repo "$REPO_SLUG" --yes || true
done < <(gh release view "$TAG" --repo "$REPO_SLUG" --json assets --jq '.assets[].name')

# --- 3. Render a local copy for the workflow artifact ------------------------

if [ -n "$STAGE_DIR" ]; then
  mkdir -p "$STAGE_DIR"
  DETAIL_ARGS=(
    --detail "Version=<code>$BUILD_NAME</code>"
    --detail "Build=<code>$BUILD_NUMBER</code>"
    --detail "Bundle ID=<code>$BUNDLE_ID</code>"
    --detail "Commit=<a href=\"https://github.com/$REPO_SLUG/commit/$SOURCE_SHA\"><code>${SOURCE_SHA:0:7}</code></a>"
  )
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
fi

# --- 4. Report ---------------------------------------------------------------

report() {
  echo "page-url=$PAGE_URL"
  echo "manifest-url=$MANIFEST_URL"
  echo "ipa-url=$IPA_URL"
  echo "tag=$TAG"
}

report
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  report >> "$GITHUB_OUTPUT"
fi
