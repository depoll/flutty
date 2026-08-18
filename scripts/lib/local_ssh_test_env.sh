#!/bin/bash

# Shared localhost SSH-key setup for manual and end-to-end test harnesses.

local_ssh_test_restore_mode() {
    local auth_keys="$1"
    local mode_file="$2"
    if [ -f "$mode_file" ]; then
        chmod "$(cat "$mode_file")" "$auth_keys"
    else
        chmod 600 "$auth_keys"
    fi
}

local_ssh_test_prepare() {
    local state_dir="$1"
    local key_comment="$2"
    local marker="$3"
    local auth_keys="${4:-$HOME/.ssh/authorized_keys}"
    local key_path="$state_dir/id_ed25519"
    local mode_file="$state_dir/authorized_keys.mode"
    local created_file="$state_dir/authorized_keys.created"

    mkdir -p "$state_dir" "$HOME/.ssh"
    chmod 700 "$state_dir" "$HOME/.ssh"

    if [ -f "$auth_keys" ] && [ ! -f "$mode_file" ]; then
        stat -f '%Lp' "$auth_keys" > "$mode_file" 2>/dev/null ||
            stat -c '%a' "$auth_keys" > "$mode_file"
    elif [ ! -f "$auth_keys" ]; then
        : > "$auth_keys"
        : > "$created_file"
    fi

    grep -Fv "$marker" "$auth_keys" > "${auth_keys}.monkeyssh-test.tmp" || true
    mv "${auth_keys}.monkeyssh-test.tmp" "$auth_keys"

    rm -f "$key_path" "${key_path}.pub"
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "$key_comment" -q
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
    printf '%s %s\n' "$(cat "${key_path}.pub")" "$marker" >> "$auth_keys"
    chmod 600 "$auth_keys"

    if ! ssh -i "$key_path" -o StrictHostKeyChecking=no -o BatchMode=yes \
        -o ConnectTimeout=2 localhost "echo ok" &>/dev/null; then
        echo "❌ Cannot SSH to localhost with the generated test key."
        local_ssh_test_teardown "$state_dir" "$marker" "$auth_keys"
        return 1
    fi

    LOCAL_SSH_TEST_KEY_PATH="$key_path"
    export LOCAL_SSH_TEST_KEY_PATH
}

local_ssh_test_teardown() {
    local state_dir="$1"
    local marker="$2"
    local auth_keys="${3:-$HOME/.ssh/authorized_keys}"
    local mode_file="$state_dir/authorized_keys.mode"
    local created_file="$state_dir/authorized_keys.created"

    if [ -f "$auth_keys" ]; then
        grep -Fv "$marker" "$auth_keys" > "${auth_keys}.monkeyssh-test.tmp" || true
        mv "${auth_keys}.monkeyssh-test.tmp" "$auth_keys"
        local_ssh_test_restore_mode "$auth_keys" "$mode_file"
        if [ -f "$created_file" ] && [ ! -s "$auth_keys" ]; then
            rm -f "$auth_keys"
        fi
    fi
    rm -f \
        "$state_dir/id_ed25519" \
        "$state_dir/id_ed25519.pub" \
        "$mode_file" \
        "$created_file"
}
