# Store assets refresh prompt

Use this prompt when MonkeySSH needs refreshed App Store or Google Play assets:

```text
Refresh the MonkeySSH store assets for the next release.

Work in a separate worktree. Review README.md, docs/deployment.md, docs/privacy-policy.md, the current Fastlane metadata under ios/fastlane and android/fastlane, and any recent product changes. Update the App Store and Play Store listing copy, release notes, screenshots, Play Store feature graphic/icons, and privacy/support URLs only when they need to change. Keep production and private/beta metadata aligned while preserving their different app names and beta wording.

Regenerate repository-managed screenshots with scripts/generate_store_screenshots.py after installing Pillow (`python3 -m pip install Pillow`). Generate short real-capture demo videos with scripts/generate_store_demo_videos.py. The screenshots and videos must be captured from the normal MonkeySSH app running on simulators/emulators with seeded release-demo data and a live temporary local SSH/MonkeyMux workspace, not individual screens mounted directly, scripted terminal transcripts, synthetic mockups, or screenshot slideshows. Each device is recorded once and composed into store-compliant deliverables: App Store **app previews** are full-screen native captures at the exact device slot resolution (iPhone 886x1920, iPad 1200x1600) with fading caption overlays and a silent audio track, because App Store Connect validates resolution at upload; the **Google Play preview** is a 16:9 landscape branded promo (1920x1080) uploaded to YouTube and referenced by URL; the portrait **branded canvas** with explanatory copy is kept for ads. Caption copy must avoid superlatives/rankings, calls-to-action, prices, and time-sensitive references on both stores. Use a uniquely named MonkeyMux session for each run so the generator never kills or reuses unrelated remote sessions. The demo flow walks Claude Code, the MonkeyMux window switcher, OpenCode, a real image paste, and Copilot. The MonkeyMux selector should show the current supported agent family: Copilot CLI, Gemini CLI, Claude Code, Codex, OpenCode, Antigravity, and Cursor Agent. Do not use port forwards, subscription, or checkout screens as primary store screenshots or demo-video scenes unless the product direction changes. Do not use raw idle CLI panes, splash screens, half-ready terminal states, account banners, visible API keys, local private paths, system error dialogs, or mostly empty lists; Claude Code's API Usage Billing label is acceptable only when the API key itself is hidden. If a real SSH/MonkeyMux workspace cannot be launched safely, stop and ask before substituting any fallback. Keep iPhone and iPad screenshots under ios/fastlane/screenshots/en-US. Keep iOS App Preview videos (iphone_67_1.mov, ipad_13_1.mov) under ios/fastlane/app-previews/en-US. Keep Android phone, 7-inch tablet, and 10-inch tablet screenshots under android/fastlane/metadata-*/android/en-US/images/{phoneScreenshots,sevenInchScreenshots,tenInchScreenshots}. Keep the Google Play landscape promo under store/demo-videos/google-play and the portrait ad exports under store/demo-videos/ads; Google Play listing videos are externally hosted, so the Play promo MP4 is uploaded to YouTube rather than synced by Fastlane. Make sure Fastlane continues to upload metadata, images, screenshots, and the committed iOS app previews from the repository.

Validate Android Play Store text limits with scripts/validate_play_store_metadata.py, App Store text limits with scripts/validate_app_store_metadata.py, screenshot counts/dimensions with scripts/validate_store_screenshots.py, and demo-video dimensions/duration with scripts/validate_store_demo_videos.py. Run any existing formatting or lightweight checks needed for touched scripts and docs. Commit the changes, push the branch, and open a PR with a summary of the updated assets and validation.
```

## Asset locations

| Store | Location |
| --- | --- |
| App Store metadata | `ios/fastlane/metadata-production` and `ios/fastlane/metadata-private` |
| App Store App Preview videos | `ios/fastlane/app-previews/en-US` (iphone_67_1.mov 886x1920, ipad_13_1.mov 1200x1600) |
| App Store screenshots | `ios/fastlane/screenshots/en-US` for iPhone and iPad |
| Google Play preview (YouTube source) | `store/demo-videos/google-play` (landscape 1920x1080) |
| Portrait ad/marketing videos | `store/demo-videos/ads` |
| Play Store metadata | `android/fastlane/metadata-production/android/en-US` and `android/fastlane/metadata-private/android/en-US` |
| Play Store screenshots | `android/fastlane/metadata-*/android/en-US/images/{phoneScreenshots,sevenInchScreenshots,tenInchScreenshots}` |
| Play Store feature graphic | `android/fastlane/metadata-*/android/en-US/images/featureGraphic.png` |
| Play Store icon source | `assets/icons/monkeyssh_icon*.png` |

Store metadata syncs automatically on pushes to `main` that touch these assets. You can also run the **Sync Store Metadata** workflow manually to sync either platform and either app listing without shipping a new build.
