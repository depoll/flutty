#!/usr/bin/env bash
# Compile only the Foundation helper, without Flutter or Xcode build products.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
swiftc -module-cache-path "$TMP_DIR/module-cache" \
  "$ROOT_DIR/ios/Runner/SyncVaultFileIO.swift" \
  "$ROOT_DIR/test/scripts/sync_vault_file_io_test.swift" \
  -o "$TMP_DIR/sync-vault-tests"
"$TMP_DIR/sync-vault-tests"
