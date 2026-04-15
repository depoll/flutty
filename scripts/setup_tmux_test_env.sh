#!/bin/bash
# Sets up a local SSH + tmux environment for manual testing of the
# tmux navigation feature in the iOS Simulator.
#
# Prerequisites:
#   - macOS with Remote Login enabled (System Settings → General → Sharing)
#   - tmux installed (brew install tmux)
#   - An iOS Simulator booted (xcrun simctl list devices booted)
#
# Usage:
#   ./scripts/setup_tmux_test_env.sh          # set up everything
#   ./scripts/setup_tmux_test_env.sh teardown  # clean up
#
# What it does:
#   1. Generates a temporary ed25519 SSH key pair
#   2. Adds the public key to ~/.ssh/authorized_keys
#   3. Verifies SSH connectivity to localhost
#   4. Creates a tmux session with sample windows
#   5. Prints instructions for manual testing in the app
#
# After setup, add a host in MonkeySSH pointing to localhost with the
# generated key, connect, and the tmux navigator should detect the
# running tmux session.

set -euo pipefail

KEY_PATH="/tmp/monkeyssh_tmux_test_key"
TMUX_SESSION="monkeyssh-test"
AUTH_KEYS="$HOME/.ssh/authorized_keys"
MARKER="# monkeyssh-tmux-test"

restore_auth_keys_permissions() {
    local mode
    mode="$(stat -f '%Lp' "$AUTH_KEYS" 2>/dev/null || true)"
    if [ -n "$mode" ]; then
        chmod "$mode" "$AUTH_KEYS"
    else
        chmod 600 "$AUTH_KEYS"
    fi
}

teardown() {
    echo "🧹 Tearing down tmux test environment..."

    # Kill tmux session
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TMUX_SESSION"
        echo "   Killed tmux session '$TMUX_SESSION'"
    fi

    # Remove test key from authorized_keys
    if [ -f "$AUTH_KEYS" ] && grep -q "$MARKER" "$AUTH_KEYS"; then
        grep -v "$MARKER" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp"
        mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
        restore_auth_keys_permissions
        echo "   Removed test key from authorized_keys"
    fi

    # Remove key files
    rm -f "$KEY_PATH" "${KEY_PATH}.pub"
    echo "   Removed key files"

    echo "✅ Teardown complete."
}

if [ "${1:-}" = "teardown" ]; then
    teardown
    exit 0
fi

echo "🔧 Setting up tmux test environment..."
echo ""

# ── Step 1: Check prerequisites ──────────────────────────────────────

if ! command -v tmux &>/dev/null; then
    echo "❌ tmux not found. Install with: brew install tmux"
    exit 1
fi

if ! ssh -o BatchMode=yes -o ConnectTimeout=2 localhost "echo ok" &>/dev/null; then
    echo "❌ Remote Login (SSH) is not enabled or not accessible."
    echo "   Enable via: System Settings → General → Sharing → Remote Login"
    exit 1
fi

# ── Step 2: Generate SSH key ─────────────────────────────────────────

if [ -f "$KEY_PATH" ]; then
    echo "   Using existing test key at $KEY_PATH"
else
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "monkeyssh-tmux-test" -q
    echo "   Generated test key: $KEY_PATH"
fi

# ── Step 3: Authorize the key ────────────────────────────────────────

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# Remove any previous test key
if [ -f "$AUTH_KEYS" ] && grep -q "$MARKER" "$AUTH_KEYS"; then
    grep -v "$MARKER" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp"
    mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    restore_auth_keys_permissions
fi

# Add new key with marker comment
echo "$(cat "${KEY_PATH}.pub") $MARKER" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
echo "   Added test key to authorized_keys"

# ── Step 4: Verify SSH connectivity ──────────────────────────────────

if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes \
    localhost "echo ok" &>/dev/null; then
    echo "   SSH connectivity verified ✓"
else
    echo "❌ Cannot SSH to localhost with the test key."
    echo "   Check that Remote Login is enabled and allows your user."
    teardown
    exit 1
fi

# ── Step 5: Create tmux session ──────────────────────────────────────

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux kill-session -t "$TMUX_SESSION"
fi

tmux new-session -d -s "$TMUX_SESSION" -n "shell"
tmux send-keys -t "$TMUX_SESSION:shell" "echo 'Welcome to MonkeySSH test environment'" Enter

tmux new-window -t "$TMUX_SESSION" -n "editor"
tmux send-keys -t "$TMUX_SESSION:editor" "echo 'Editor window — try running vim or nano'" Enter

tmux new-window -t "$TMUX_SESSION" -n "logs"
tmux send-keys -t "$TMUX_SESSION:logs" "echo 'Logs window — try running tail -f'" Enter

tmux select-window -t "$TMUX_SESSION:shell"

echo "   Created tmux session '$TMUX_SESSION' with 3 windows"

# ── Done ─────────────────────────────────────────────────────────────

WINDOW_COUNT=$(tmux list-windows -t "$TMUX_SESSION" | wc -l | tr -d ' ')

echo ""
echo "✅ Test environment ready!"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  SSH Host:     localhost                                │"
echo "│  Username:     $(printf '%-39s' "$USER")│"
echo "│  Port:         22                                       │"
echo "│  Key:          $KEY_PATH"
echo "│  tmux session: $TMUX_SESSION ($WINDOW_COUNT windows)"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "To test in MonkeySSH:"
echo "  1. Run the app:  flutter run"
echo "  2. Add a new host:"
echo "     • Label:    Local tmux"
echo "     • Hostname: localhost"
echo "     • Username: $USER"
echo "     • Import key from: $KEY_PATH"
echo "     • Auto-connect: tmux new-session -A -s $TMUX_SESSION"
echo "  3. Tap the host to connect"
echo "  4. Look for the tmux icon (⊞) in the toolbar"
echo "  5. Tap it to open the tmux navigator"
echo ""
echo "To tear down:  ./scripts/setup_tmux_test_env.sh teardown"
