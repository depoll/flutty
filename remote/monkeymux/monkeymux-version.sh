#!/usr/bin/env sh
# Prints the MonkeyMux helper version.
#
# `monkeyMuxVersion` in main.go is the single source of truth: it is compiled
# into the helper and reported to clients in the server `hello` frame, and the
# helper only restarts a running server when that constant differs from the
# running version. Deriving the packaging version from the same constant keeps
# assets/monkeymux/manifest.json in step with the binary it ships. When the two
# drift, MonkeySSH offers "update and restore" that the helper then declines as
# a no-op, so the prompt reappears on every connect.
set -e

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
version="$(
  sed -n 's/^[[:space:]]*monkeyMuxVersion[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$script_dir/main.go" | head -n 1
)"

if [ -z "$version" ]; then
  echo "monkeymux-version.sh: could not read monkeyMuxVersion from main.go" >&2
  exit 1
fi

printf '%s\n' "$version"
