# Store assets refresh prompt

Use this prompt when MonkeySSH needs refreshed App Store or Google Play assets:

```text
Refresh the MonkeySSH store assets for the next release.

Work in a separate worktree. Review README.md, docs/deployment.md, docs/privacy-policy.md, the current Fastlane metadata under ios/fastlane and android/fastlane, and any recent product changes. Update the App Store and Play Store listing copy, release notes, screenshots, feature graphic, icons, and privacy/support URLs only when they need to change. Keep production and private/beta metadata aligned while preserving their different app names and beta wording.

Regenerate repository-managed screenshots with scripts/generate_store_screenshots.py. The screenshots must be captured from the normal MonkeySSH app running on simulators/emulators with seeded release-demo data and a live temporary local SSH/tmux workspace, not individual screens mounted directly, scripted terminal transcripts, or synthetic mockups. Keep the first screenshot as a real terminal showing Claude Code and/or GitHub Copilot in streamer/privacy-safe mode, followed by Hosts, Snippets, the tmux window selector, and SFTP or another polished real app surface. Do not use port forwards, subscription, or checkout screens as primary store screenshots unless the product direction changes. Do not use raw idle CLI panes, splash screens, half-ready terminal states, account/billing banners, local private paths, or mostly empty lists. If a real SSH/tmux workspace cannot be launched safely, stop and ask before substituting any fallback. Keep iPhone and iPad screenshots under ios/fastlane/screenshots/en-US. Keep Android phone, 7-inch tablet, and 10-inch tablet screenshots under android/fastlane/metadata-*/android/en-US/images/{phoneScreenshots,sevenInchScreenshots,tenInchScreenshots}. Make sure Fastlane continues to upload metadata, images, and screenshots from the repository.

Validate Android Play Store text limits with scripts/validate_play_store_metadata.py, App Store text limits with scripts/validate_app_store_metadata.py, and screenshot counts/dimensions with scripts/validate_store_screenshots.py. Run any existing formatting or lightweight checks needed for touched scripts and docs. Commit the changes, push the branch, and open a PR with a summary of the updated assets and validation.
```

## Asset locations

| Store | Location |
| --- | --- |
| App Store metadata | `ios/fastlane/metadata-production` and `ios/fastlane/metadata-private` |
| App Store screenshots | `ios/fastlane/screenshots/en-US` for iPhone and iPad |
| Play Store metadata | `android/fastlane/metadata-production/android/en-US` and `android/fastlane/metadata-private/android/en-US` |
| Play Store screenshots | `android/fastlane/metadata-*/android/en-US/images/{phoneScreenshots,sevenInchScreenshots,tenInchScreenshots}` |
| Play Store feature graphic | `android/fastlane/metadata-*/android/en-US/images/featureGraphic.png` |

Store metadata syncs automatically on pushes to `main` that touch these assets. You can also run the **Sync Store Metadata** workflow manually to sync either platform and either app listing without shipping a new build.
