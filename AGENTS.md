# Repository notes for agents

- Use JDK 17 for Android/Gradle builds in this repo. JDK 25 fails in the Android/Kotlin toolchain with `IllegalArgumentException: 25.0.1`.
- On macOS, set `JAVA_HOME="$(/usr/libexec/java_home -v 17)"` before running `flutter build ...` or `./gradlew ...` for Android.

## iOS provisioning profiles after capability changes

After enabling a new App ID capability in the Apple Developer portal (e.g. Access WiFi Information, Push Notifications, App Groups), the existing provisioning profiles in the match git repo are stale — they don't include the new entitlement, so signing with the new entitlements file in `ios/Runner/Runner.entitlements` will fail.

Refresh once via the **Regenerate iOS Provisioning Profiles** GitHub Actions workflow (`workflow_dispatch`), or run locally:

```bash
cd ios
bundle exec fastlane regenerate_profiles            # both Private + Production
bundle exec fastlane regenerate_profiles scheme:Private
```

Local Xcode builds with automatic signing pick up the new entitlement on next build without any extra step (Xcode regenerates dev profiles via the developer portal automatically).

## Manual testing: tmux navigation

The tmux navigator feature requires a real SSH connection to a host running tmux. Use the setup script to create a local test environment:

```bash
# Set up local SSH + tmux test environment
./scripts/setup_tmux_test_env.sh

# Run the app in a simulator
flutter run --device-id <simulator-id>

# When done, tear down
./scripts/setup_tmux_test_env.sh teardown
```

The script generates a temporary SSH key, authorizes it for localhost, and creates a tmux session with 3 windows. Follow the on-screen instructions to add a host in the app and test the navigator.

### Key gotchas for tmux over SSH exec channels

- **PATH**: SSH exec channels use a minimal PATH that excludes Homebrew. The tmux service sources `~/.profile`, `~/.bash_profile`, and `~/.zprofile` before running commands.
- **Format strings**: tmux's `-F` option does **not** interpret `\t` as tab. Use ASCII Unit Separator (`\x1f`) delimiters instead so window names and titles can still contain `|`.
- **Environment variables**: Exec channels don't share the interactive shell's environment. Use `tmux list-sessions` / `tmux display-message` instead of `echo $TMUX`.

## Diagnostics logging

Preview and beta/internal builds expose an in-memory diagnostics log in Settings > Diagnostics. Users can tap **Copy diagnostics log** and paste the sanitized text into an issue or chat for troubleshooting.

When adding diagnostics, use `DiagnosticsLogService.instance` (or `diagnosticsLogServiceProvider` in UI code) and keep entries structured with a short category, short event name, and primitive fields. The logger is gated to diagnostics-enabled preview/beta builds and maintains a bounded ring buffer.

Never log secrets or user content. Do not log hostnames, usernames, passwords, passphrases, private keys, tokens, raw commands, terminal output, tmux window/session names, window titles, working directories, file paths, clipboard contents, or raw SSH/tmux stream lines. Prefer safe metadata such as connection ID, host ID, booleans, counts, durations, enum states, retry attempts, error types, exit statuses, and sanitized event categories.

For tmux control-mode logging, log the control marker category (for example `subscription_changed` or `window_add`) and counts/timing only. Do not log the full control-mode line because it can include pane titles, window names, paths, and command output.
