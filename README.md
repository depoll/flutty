# MonkeySSH

**MonkeySSH is the SSH workspace for agentic coding.** It combines a serious mobile terminal, SFTP workspace, MonkeyMux/tmux remote windows, and first-class launch/resume flows for modern coding agents.

[![CI](https://github.com/depollsoft/MonkeySSH/actions/workflows/ci.yml/badge.svg)](https://github.com/depollsoft/MonkeySSH/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

MonkeySSH is built for the way people work with remote development environments now: connect to a box, attach to a persistent agent workspace, switch remote windows, resume the right agent session, browse files, edit config, forward a port, paste commands safely, and keep moving without a laptop.

## Why MonkeySSH

- **Built for agent workflows** with scoped recent-session discovery and saved launch presets per host
- **MonkeyMux and tmux aware** so long-running coding sessions survive reconnects and stay easy to resume
- **A real SSH workspace** with terminal, SFTP, remote editing, snippets, key management, jump hosts, and port forwarding
- **Mobile-first terminal UX** with modifier keys, gestures, IME-friendly text input, safer paste review, shared clipboard, clickable file paths, and responsive window navigation
- **Private by default** with local auth, host-key verification, encrypted offline transfers, no required cloud sync, and opt-in analytics/crash reporting that starts off

## Built for agentic coding

MonkeySSH is designed around the tools and workflows people use for remote AI-assisted development.

- **Recent agent session discovery** for supported CLIs, scoped to the active project so you can jump back into the right conversation faster
- **Saved launch presets** for tools like Claude Code, Copilot CLI, Codex, Gemini CLI, OpenCode, Antigravity, Cursor Agent, Pi, Hermes, and OpenClaw
- **Per-host startup flows** with working-directory changes, MonkeyMux/tmux session names, extra arguments, and optional one-tap automation
- **Remote window navigation** for discovering sessions and windows, tracking the active pane path, launching agents into persistent workspaces, and switching windows from a bottom sheet or wide-screen sidebar
- **IME keyboard support** so autocorrect, suggestions, swipe typing, keyboard dictation, and password-friendly prompt input behave more like a normal mobile text field, even in a terminal
- **Safer command handling** with review prompts for suspicious pasted or auto-run shell text before it is inserted or executed
- **Remote clipboard sync** so it is easier to move code and commands between your device and the remote machine

## Feature overview

| Area | What you get |
| --- | --- |
| **SSH connections** | Password and key auth, jump hosts, cancellable connection attempts, multiple concurrent sessions, host organization, search, favorites, home-screen shortcuts |
| **Terminal** | xterm-256color, customizable themes, adjustable fonts, modifier keys, function keys, gestures, macros, bell, inline images and animations, tap-to-show keyboard, and IME-friendly typing with autocorrect, swipe, keyboard dictation, and password-friendly prompt input |
| **Coding workflow** | AI session picker, scoped recent session resume, MonkeyMux/tmux launch flows, multi-client MonkeyMux sessions shared with your desktop, window switcher, wide-screen sidebar, clickable file paths, shared clipboard, safer paste review |
| **Files** | SFTP browser, upload/download, remote file creation, direct remote text editing, syntax highlighting, path-aware navigation from terminal output |
| **Automation** | Snippets, variable-aware snippet insertion, host auto-connect commands, saved agent launch presets |
| **Networking** | Local and remote port forwards for tunnels, dashboards, previews, and remote services, live per-session forward controls, automatic proxying for detected remote listeners, an in-app browser for forwarded ports with file uploads, downloads, and site permissions, and Android device debugging over the current SSH session |
| **Keys and trust** | Generate/import/export Ed25519 and RSA keys, verify SSH host fingerprints, track trusted hosts locally |
| **Security and portability** | PIN + biometrics, auto-lock, encrypted offline transfer bundles, encrypted full-app migration packages, no required cloud sync, telemetry sharing off by default |

## MonkeySSH Pro

MonkeySSH Pro unlocks the features that matter most for power users and multi-device workflows:

- encrypted host and key transfers
- full migration import/export
- auto-connect automation
- agent launch presets
- host-specific terminal themes

Core SSH, terminal, SFTP, and everyday remote access stay front and center regardless.

## Privacy and telemetry

MonkeySSH stores hosts, keys, snippets, transfer packages, and settings on device. SSH, SFTP, clipboard, and port-forwarding traffic goes directly between your device and the servers you configure.

Firebase Analytics and Crashlytics are compiled only into telemetry-enabled builds and stay off until you opt in. Opt-in analytics uses coarse allowlisted events for broad feature usage, setup funnels, connection reliability, SFTP transfer outcomes, remote window usage, and agent launch/session-history usage. It excludes hostnames, usernames, IP addresses, commands, terminal output, file paths, file names, tmux session/window names, clipboard contents, passwords, passphrases, private keys, tokens, and raw SSH/SFTP/tmux data.

## Release focus

MonkeySSH is being prepared for public release with production App Store and Play Store deployment flows already in place. The app is built with Flutter, so the codebase remains portable, but the current release pipeline and store metadata are centered on **iPhone and Android**.

## Development

```bash
./scripts/ensure_monkeymux_assets.sh
flutter pub get
dart run build_runner build
flutter analyze
dart format .
flutter test
```

MonkeyMux executables are generated build outputs rather than Git-tracked
files. The ensure script cross-compiles all supported remote-host targets with
the pinned Go toolchain and skips the work when its inputs have not changed.

### Android builds

Use **JDK 17** for Android and Gradle work in this repo:

```bash
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
```

### Integration and manual testing

```bash
flutter test integration_test
```

To test tmux navigation against a real SSH target:

```bash
./scripts/setup_tmux_test_env.sh
# ... run the app and connect to localhost ...
./scripts/setup_tmux_test_env.sh teardown
```

## Deployment

Release automation, app variants, store setup, and signing details live in [docs/deployment.md](docs/deployment.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
