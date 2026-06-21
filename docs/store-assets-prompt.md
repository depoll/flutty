# Store assets refresh prompt

Use this prompt when MonkeySSH needs refreshed App Store or Google Play assets:

```text
Refresh the MonkeySSH store assets for the next release.

Work in a separate worktree. Review README.md, docs/deployment.md, docs/privacy-policy.md, the current Fastlane metadata under ios/fastlane and android/fastlane, and any recent product changes. Update the App Store and Play Store listing copy, release notes, screenshots, Play Store feature graphic/icons, and privacy/support URLs only when they need to change. Keep production and private/beta metadata aligned while preserving their different app names and beta wording.

Regenerate repository-managed screenshots with scripts/generate_store_screenshots.py after installing Pillow (`python3 -m pip install Pillow`). Generate short real-capture demo videos with scripts/generate_store_demo_videos.py; add `--ios-app-preview` when the iOS recording should be committed for App Store Connect. The screenshots and videos must be captured from the normal MonkeySSH app running on simulators/emulators with seeded release-demo data and a live temporary local SSH/MonkeyMux workspace, not individual screens mounted directly, scripted terminal transcripts, synthetic mockups, or screenshot slideshows. Use a uniquely named MonkeyMux session for each run so the generator never kills or reuses unrelated remote sessions. Keep the feature order as real GitHub Copilot terminal, Hosts, Snippets, MonkeyMux window selector, SFTP, and real Claude Code terminal. The MonkeyMux selector should show the current supported agent family: Copilot CLI, Gemini CLI, Claude Code, Codex, OpenCode, and Antigravity. Do not use port forwards, subscription, or checkout screens as primary store screenshots or demo-video scenes unless the product direction changes. Do not use raw idle CLI panes, splash screens, half-ready terminal states, account banners, visible API keys, local private paths, or mostly empty lists; Claude Code's API Usage Billing label is acceptable only when the API key itself is hidden. If a real SSH/MonkeyMux workspace cannot be launched safely, stop and ask before substituting any fallback. Keep iPhone and iPad screenshots under ios/fastlane/screenshots/en-US. Keep iOS App Preview videos under ios/fastlane/app-previews/en-US. Keep Android phone, 7-inch tablet, and 10-inch tablet screenshots under android/fastlane/metadata-*/android/en-US/images/{phoneScreenshots,sevenInchScreenshots,tenInchScreenshots}. Keep committed Android demo videos under store/demo-videos/android; Google Play listing videos are externally hosted promo videos, so Android MP4 files are not uploaded by Fastlane metadata sync. Make sure Fastlane continues to upload metadata, images, screenshots, and any committed iOS app previews from the repository.

Validate Android Play Store text limits with scripts/validate_play_store_metadata.py, App Store text limits with scripts/validate_app_store_metadata.py, screenshot counts/dimensions with scripts/validate_store_screenshots.py, and demo-video dimensions/duration with scripts/validate_store_demo_videos.py. Run any existing formatting or lightweight checks needed for touched scripts and docs. Commit the changes, push the branch, and open a PR with a summary of the updated assets and validation.
```

## Asset locations

| Store | Location |
| --- | --- |
| App Store metadata | `ios/fastlane/metadata-production` and `ios/fastlane/metadata-private` |
| App Store App Preview videos | `ios/fastlane/app-previews/en-US` |
| App Store screenshots | `ios/fastlane/screenshots/en-US` for iPhone and iPad |
| Android demo/ad videos | `store/demo-videos/android` |
| Play Store metadata | `android/fastlane/metadata-production/android/en-US` and `android/fastlane/metadata-private/android/en-US` |
| Play Store screenshots | `android/fastlane/metadata-*/android/en-US/images/{phoneScreenshots,sevenInchScreenshots,tenInchScreenshots}` |
| Play Store feature graphic | `android/fastlane/metadata-*/android/en-US/images/featureGraphic.png` |
| Play Store icon source | `assets/icons/monkeyssh_icon*.png` |

Store metadata syncs automatically on pushes to `main` that touch these assets. You can also run the **Sync Store Metadata** workflow manually to sync either platform and either app listing without shipping a new build.
