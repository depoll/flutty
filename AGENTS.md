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

## Manual testing: Android emulator local SSH

For Android emulator validation against the Mac host, use `10.0.2.2` from the emulator to reach services bound to `127.0.0.1` on macOS. Run the private flavor with JDK 17:

```bash
JAVA_HOME="$(/usr/libexec/java_home -v 17)" \
  flutter run -d emulator-5554 --debug --flavor private -t lib/main.dart
```

A no-auth Paramiko SSH server is useful for quick simulator testing, but make it behave like the Mac default SSH environment:

- Use `/bin/zsh` for both shell channels and exec probes (`/bin/zsh -lc <command>`).
- Set `SHELL=/bin/zsh`, `TERM=xterm-256color`, `COLORTERM=truecolor`, and include Homebrew in `PATH` (`/Users/depoll/homebrew/bin`, `/opt/homebrew/bin`, `/usr/local/bin`).
- Do not launch `bash --noprofile --norc`; it hides Homebrew tools and does not match a normal Mac SSH session.
- Build a clean environment instead of copying the agent process environment; inherited variables such as `TMUX` make TUIs think they are running inside tmux and can change their terminal protocol behavior.
- For opencode system-theme testing, create a temp HOME with `.config/opencode/tui.json` containing `{"theme":"system"}`.

In the app, create or seed a host with hostname `10.0.2.2`, the test server port (for example `2223`), the test username, and no password/key for no-auth. Leave auto-connect fields empty unless you specifically need to test Pro-gated auto-connect behavior. To start a TUI without fragile ADB text input, put a temporary zsh startup command such as `exec opencode --pure` in the test HOME `.zshrc`, then remove it when done.

Useful emulator commands:

```bash
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" shell cmd uimode night no      # light mode
"$ADB" shell cmd uimode night yes     # dark mode
"$ADB" exec-out screencap -p > /tmp/monkeyssh.png
```

ADB text injection is IME-dependent. Prefer separate key events for spaces (`adb shell input keyevent SPACE`) rather than relying on escaped spaces in `adb shell input text`.

### Key gotchas for tmux over SSH exec channels

- **PATH**: SSH exec channels use a minimal PATH that excludes Homebrew. The tmux service sources `~/.profile`, `~/.bash_profile`, and `~/.zprofile` before running commands.
- **Format strings**: tmux's `-F` option does **not** interpret `\t` as tab. Use ASCII Unit Separator (`\x1f`) delimiters instead so window names and titles can still contain `|`.
- **Environment variables**: Exec channels don't share the interactive shell's environment. Use `tmux list-sessions` / `tmux display-message` instead of `echo $TMUX`.

## Diagnostics logging

Preview and beta/internal builds expose an in-memory diagnostics log in Settings > Diagnostics. Users can tap **Copy diagnostics log** and paste the sanitized text into an issue or chat for troubleshooting.

When adding diagnostics, use `DiagnosticsLogService.instance` (or `diagnosticsLogServiceProvider` in UI code) and keep entries structured with a short category, short event name, and primitive fields. The logger is gated to diagnostics-enabled preview/beta builds and maintains a bounded ring buffer.

Never log secrets or user content. Do not log hostnames, usernames, passwords, passphrases, private keys, tokens, raw commands, terminal output, tmux window/session names, window titles, working directories, file paths, clipboard contents, or raw SSH/tmux stream lines. Prefer safe metadata such as connection ID, host ID, booleans, counts, durations, enum states, retry attempts, error types, exit statuses, and sanitized event categories.

For tmux control-mode logging, log the control marker category (for example `subscription_changed` or `window_add`) and counts/timing only. Do not log the full control-mode line because it can include pane titles, window names, paths, and command output.
