# Repository notes for agents

- Use JDK 17 for Android/Gradle builds in this repo. JDK 25 fails in the Android/Kotlin toolchain with `IllegalArgumentException: 25.0.1`.
- On macOS, set `JAVA_HOME="$(/usr/libexec/java_home -v 17)"` before running `flutter build ...` or `./gradlew ...` for Android.

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
- **Format strings**: tmux's `-F` option does **not** interpret `\t` as tab. Use `|` pipe delimiters instead.
- **Environment variables**: Exec channels don't share the interactive shell's environment. Use `tmux list-sessions` / `tmux display-message` instead of `echo $TMUX`.
