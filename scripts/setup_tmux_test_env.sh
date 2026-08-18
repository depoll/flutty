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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/local_ssh_test_env.sh
source "$SCRIPT_DIR/lib/local_ssh_test_env.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/monkeyssh/tmux-test"
KEY_PATH="$STATE_DIR/id_ed25519"
TMUX_SESSION="monkeyssh-test"
AUTH_KEYS="$HOME/.ssh/authorized_keys"
MARKER="# monkeyssh-tmux-test"

teardown() {
    echo "🧹 Tearing down tmux test environment..."

    # Kill tmux session
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TMUX_SESSION"
        echo "   Killed tmux session '$TMUX_SESSION'"
    fi

    local_ssh_test_teardown "$STATE_DIR" "$MARKER" "$AUTH_KEYS"
    echo "   Removed key files"

    echo "✅ Teardown complete."
}

if [ "${1:-}" = "teardown" ]; then
    teardown
    exit 0
fi

echo "🔧 Setting up tmux test environment..."
echo ""

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# ── Step 1: Check prerequisites ──────────────────────────────────────

if ! command -v tmux &>/dev/null; then
    echo "❌ tmux not found. Install with: brew install tmux"
    exit 1
fi

local_ssh_test_prepare "$STATE_DIR" "monkeyssh-tmux-test" "$MARKER" "$AUTH_KEYS"
echo "   Generated and verified test key: $KEY_PATH"

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
