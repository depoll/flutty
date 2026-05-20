## Summary

This PR adds support for the **Antigravity CLI** agent to MonkeySSH.

### Features
- **Launch Presets**: Users can now select "Antigravity" from the agent launch tool list.
- **Session Discovery**: The app will now automatically discover recent Antigravity sessions stored in `~/.antigravity/sessions/*.json`.
- **YOLO Mode**: Full support for launching and resuming sessions in YOLO mode via the `--yolo` flag.
- **Tmux Integration**: Updated tmux window tracking to correctly identify and alias Antigravity terminal titles.

### Changes
- Added `antigravity` to `AgentLaunchTool`.
- Implemented `_discoverAntigravitySessions` in `AgentSessionDiscoveryService`.
- Updated `tmux_state.dart` for exhaustive matching and session ID extraction.
- Added comprehensive unit tests for presets and discovery.

### Verification
- Ran `flutter test test/domain/models/agent_launch_preset_test.dart` (Passed)
- Ran `flutter test test/domain/services/agent_session_discovery_service_test.dart` (Passed)
- Ran `flutter test test/widget/tmux_window_navigator_test.dart` (Passed)
