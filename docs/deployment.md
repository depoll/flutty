# Deployment Guide

This guide covers setting up automated deployment to TestFlight, Play Store internal testing, internal-only production release candidates, and public store releases.

## App Variants

| Variant | Android Package | iOS Bundle ID | Display Name | Purpose |
|---------|----------------|---------------|--------------|---------|
| **private** | `xyz.depollsoft.monkeyssh.private` | `xyz.depollsoft.monkeyssh.private` | MonkeySSH β | PR previews, internal testing |
| **production** | `xyz.depollsoft.monkeyssh` | `xyz.depollsoft.monkeyssh` | MonkeySSH | App Store / Play Store releases |

Both variants install side-by-side on the same device.

## Prerequisites

### Apple Developer Account

1. Log in to [App Store Connect](https://appstoreconnect.apple.com/)
2. Create **two** apps:
   - Bundle ID: `xyz.depollsoft.monkeyssh` — name: "MonkeySSH"
   - Bundle ID: `xyz.depollsoft.monkeyssh.private` — name: "MonkeySSH β"
3. Create an **App Store Connect API Key**:
   - Go to Users and Access → Integrations → App Store Connect API
   - Generate a new key with "App Manager" role
   - Download the `.p8` file (you can only download it once)
   - Note the **Key ID** and **Issuer ID**

### Google Play Developer Account

1. Log in to [Google Play Console](https://play.google.com/console)
2. Create **two** apps:
   - Package: `xyz.depollsoft.monkeyssh` — name: "MonkeySSH"
   - Package: `xyz.depollsoft.monkeyssh.private` — name: "MonkeySSH β"
3. Create a **Service Account**:
   - Go to Setup → API access
   - Create a new service account in Google Cloud Console
   - Grant "Service Account User" role
   - Create and download a JSON key
   - Back in Play Console, grant the service account access with "Release manager" permissions

### Fastlane Match (iOS Certificates)

1. Create a **private Git repository** for storing certificates (e.g., `github.com/yourorg/certificates`)
2. Initialize match locally:
   ```bash
   cd ios
   bundle exec fastlane match init
   ```
3. Generate certificates for every shipped iOS bundle ID, including the Live Activity extension:
    ```bash
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh.private
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh.ConnectionStatusLiveActivity
    bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh.private.ConnectionStatusLiveActivity
    ```

### Android Upload Keystore

Generate a release keystore:
```bash
keytool -genkey -v \
  -keystore upload-keystore.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias upload
```

Signed Android release builds require `android/app/key.properties` (see `key.properties.example`) and the real upload keystore. Debug builds for local development do not require release signing material.

## GitHub Secrets

Configure these secrets in your repository settings (Settings → Secrets and variables → Actions):

### iOS / Apple

| Secret | Description | How to get it |
|--------|-------------|---------------|
| `MATCH_GIT_URL` | Private Git repo URL for certificates | `https://github.com/yourorg/certificates.git` |
| `MATCH_PASSWORD` | Encryption password for match | Set during `fastlane match init` |
| `MATCH_GIT_BASIC_AUTHORIZATION` | Base64-encoded `username:PAT` | `echo -n "username:ghp_token" \| base64` |
| `APP_STORE_CONNECT_API_KEY_ID` | API Key ID | From App Store Connect → Integrations |
| `APP_STORE_CONNECT_API_ISSUER_ID` | API Issuer ID | From App Store Connect → Integrations |
| `APP_STORE_CONNECT_API_KEY_CONTENT` | API Key content (raw .p8 PEM) | Contents of `AuthKey_XXXXXX.p8` file |

### Android / Google Play

| Secret | Description | How to get it |
|--------|-------------|---------------|
| `ANDROID_KEYSTORE_BASE64` | Base64-encoded keystore | `base64 -i upload-keystore.jks` |
| `ANDROID_KEY_ALIAS` | Keystore key alias | Set during `keytool -genkey` |
| `ANDROID_KEY_PASSWORD` | Key password | Set during `keytool -genkey` |
| `ANDROID_STORE_PASSWORD` | Keystore password | Set during `keytool -genkey` |
| `PLAY_STORE_SERVICE_ACCOUNT_JSON` | Service account JSON key content | Downloaded from Google Cloud Console |

## Workflows

### PR Preview (`preview.yml`)

Triggered automatically on PRs to `main` and `develop`. Builds the **private** flavor and:
- **iOS**: Run the **Deploy PR Preview** workflow manually from the Actions tab
- **Android**: Builds a **debug** APK for direct download (linked in PR comment). Signed release artifacts remain limited to release/deploy workflows with configured secrets.

When `/deploy` promotes a PR preview, it reuses the existing unsigned preview artifacts when their build number is still ahead of the latest private deploy. If a newer private build has already been deployed, the workflow automatically rebuilds with a fresh build number before uploading to TestFlight and Play internal.

### Deploy Private (`develop.yml`)

Triggered on push to `main`. Builds the **private** flavor and deploys to:
- **iOS**: TestFlight (MonkeySSH β)
- **Android**: Play Store internal testing track

This ensures TestFlight and Play Store internal testing always reflect the latest `main`.

### Release Internal (`release-internal.yml`)

Manually triggered from the Actions tab with a version input.

Builds the **production** flavor and deploys it to internal-only channels:
- **iOS**: TestFlight internal testers for the production `MonkeySSH` app
- **Android**: Play Store internal testing track for the production `xyz.depollsoft.monkeyssh` app

Metadata is synced as part of the deploy so the production store listing stays aligned while the binary remains limited to internal testers.

Use this workflow to validate a release candidate on the non-private app before promoting a later build publicly.

### Release (`release.yml`)

Triggered by:
- Creating a GitHub Release (tag format: `vX.Y.Z`)
- Manual workflow dispatch with version input

Builds the **production** flavor and deploys to:
- **iOS**: App Store (submitted, not auto-released)
- **Android**: Play Store production track

Metadata is synced automatically on release deploys. Android listing icons are
managed as Play Store metadata; iOS App Store icons come from the submitted app
build's asset catalog.

Android release workflows fail early if the signing secrets or local `android/app/key.properties` configuration are missing or incomplete. This prevents release builds from silently falling back to the debug keystore.

### Sync Metadata (`sync-metadata.yml`)

Triggered automatically on pushes to `main` that touch repository-managed store assets, and can also be run manually to sync store metadata without a new build. Useful for updating app descriptions, screenshots, iOS App Preview videos, Android listing icons, or other listing details.

Supports selecting:
- **Platform**: iOS, Android, or both
- **App**: private, production, or both

### Build Numbers

All builds use epoch-minute build numbers (`$(date +%s) / 60`) — monotonically increasing regardless of how many PRs are active. PR info is encoded in the version name (`X.Y.Z-pr.N`), not the build number.

## Store Metadata

Store metadata is managed per-app in the repository. Each app variant (private
and production) has its own metadata directory with distinct names and listing
copy. Android also has per-variant Play Store icon metadata.

### iOS (App Store Connect)

```
ios/fastlane/
├── screenshots/
│   └── en-US/                  # Shared App Store iPhone and iPad screenshots
├── app-previews/
│   └── en-US/                  # Optional App Store product demo videos
├── metadata-private/        # MonkeySSH β (preview app)
│   ├── en-US/
│   │   ├── name.txt         # "MonkeySSH β"
│   │   ├── subtitle.txt
│   │   ├── description.txt
│   │   ├── keywords.txt
│   │   ├── release_notes.txt
│   │   ├── privacy_url.txt
│   │   └── support_url.txt
│   ├── review_information/
│   │   └── notes.txt
│   ├── copyright.txt
│   └── primary_category.txt
└── metadata-production/     # MonkeySSH (production app)
    ├── en-US/
    │   └── (same structure)
    ├── copyright.txt
    └── primary_category.txt
```

Fastlane `deliver` no longer uploads iOS App Store icons through metadata sync;
App Store Connect uses the app icon embedded in the selected build.

### Android (Google Play)

```
android/fastlane/
├── metadata-private/        # MonkeySSH β (preview app)
│   └── android/en-US/
│       ├── title.txt        # "MonkeySSH β"
│       ├── short_description.txt
│       ├── full_description.txt
│       ├── icon.png         # 512x512 (private banner icon)
│       ├── images/
│       │   ├── featureGraphic.png
│       │   ├── phoneScreenshots/
│       │   ├── sevenInchScreenshots/
│       │   └── tenInchScreenshots/
│       └── changelogs/
│           └── default.txt
└── metadata-production/     # MonkeySSH (production app)
    └── android/en-US/
        └── (same structure)
```

Edit these files and metadata will sync on the next release deploy, or trigger the **Sync Metadata** workflow manually.
Android `icon.png` files are auto-regenerated from `assets/icons/monkeyssh_icon*.png` during deploy/metadata-sync workflows, so marketplace icons stay aligned with the app icon assets.
Google Play text limits still apply to the repository files: `title.txt` must stay within 30 characters, `short_description.txt` within 80 characters, and `full_description.txt` within 4000 characters. You can validate them locally with `python3 scripts/validate_play_store_metadata.py`.
App Store text limits can be validated locally with `python3 scripts/validate_app_store_metadata.py`.
Store screenshots can be regenerated locally with `python3 scripts/generate_store_screenshots.py` after installing Pillow (`python3 -m pip install Pillow`). The generator starts a temporary local `sshd` and uniquely named MonkeyMux workspace, boots the normal MonkeySSH app on iOS simulators and an Android emulator with release-demo data, drives real app navigation through a real Copilot CLI terminal, hosts, snippets, the MonkeyMux window selector with the current supported agent family, SFTP, and a real Claude Code terminal, then captures native device screenshots into the Fastlane folders. The generator fails instead of substituting mock screenshots if the real SSH/MonkeyMux workspace cannot be created.
Generated screenshot counts, dimensions, and OCR content can be validated locally on macOS with `python3 scripts/validate_store_screenshots.py` after installing Pillow.
Short product demo videos can be recorded with `python3 scripts/generate_store_demo_videos.py [ios|android|both]` and validated with `python3 scripts/validate_store_demo_videos.py [ios|android|both]`. The video generator reuses the real screenshot capture environment, records native simulator/emulator screen video while the app moves through the same feature sequence, then composes that live capture into a branded vertical promo canvas with explanatory copy around the phone screen. By default it writes ad/review exports under `build/store-demo-videos`; pass `--ios-app-preview` to also write `ios/fastlane/app-previews/en-US/iphone_67_1.mov` for App Store Connect metadata sync. Commit Android ad/review exports under `store/demo-videos/android/` and validate them with `python3 scripts/validate_store_demo_videos.py android --output-dir store/demo-videos`. Google Play listing videos are managed as externally hosted promo videos, so Android MP4 files are not uploaded by Fastlane metadata sync.
The future refresh prompt lives in `docs/store-assets-prompt.md`.

> **Note:** Apple and Google require unique app names per account. The private app uses "MonkeySSH β" to distinguish it from the production "MonkeySSH" listing.

## Building Flavors Locally

### iOS release validation prerequisites

Use the standard Xcode bundle with the installed iOS runtime when validating iOS releases locally:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
flutter build ios --flavor production --release --no-codesign
```

Do not validate releases with a side-by-side Xcode beta or point release unless its selected SDK has a matching installed iOS runtime. For example, Xcode 26.4.1 fails when only the iOS 26.2 simulator runtime is installed; `/Applications/Xcode.app` (Xcode 26.2 on the current release image) is the supported local and CI selector.

Flutter 3.41 also warns that UIScene lifecycle support will soon be required. MonkeySSH has a custom `AppDelegate` for native method channels, document pickers, Live Activities, and foreground/background state, so the automatic Flutter migration is not safe. Track the manual migration as release work: add `UIApplicationSceneManifest`, introduce a `SceneDelegate`/`FlutterSceneDelegate`, switch plugin registration to `FlutterImplicitEngineDelegate`, and move scene foreground/background handling out of `AppDelegate` together.

```bash
# Private flavor
flutter build apk --flavor private --release
flutter build ios --flavor private --release --no-codesign

# Production flavor
flutter build apk --flavor production --release
flutter build ios --flavor production --release --no-codesign

# With custom version
flutter build apk --flavor private --release --build-name=0.1.0-pr.1 --build-number=12345
```

### Firebase analytics and crash reporting

Firebase Analytics and Crashlytics are compiled into the app but disabled at
runtime unless Firebase is explicitly enabled for the build:

```bash
flutter build apk \
  --flavor production \
  --release \
  --dart-define=FLUTTY_FIREBASE_ENABLED=true
```

MonkeySSH uses Firebase project `monkeyssh`.

Before enabling that flag, provide the Firebase app config for the matching
platform/flavor:

- Android: `android/app/src/private/google-services.json` and
  `android/app/src/production/google-services.json`
- iOS: `ios/Runner/Firebase/private/GoogleService-Info.plist` and
  `ios/Runner/Firebase/production/GoogleService-Info.plist`

The config files are ignored by git so release automation should write them
from encrypted secrets before the build. Without these files, the app keeps
telemetry unavailable and the native Crashlytics upload phase skips dSYM upload.
The in-app Settings toggle controls both Firebase Analytics collection and
Crashlytics collection; collection defaults to off for existing and new installs.
The Android manifest and iOS Info.plist also disable Firebase collection by
default so native startup cannot collect before Dart applies the saved setting.
Firebase's current iOS pods require iOS 15 or newer. iOS builds use CocoaPods
with `FLUTTER_SWIFT_PACKAGE_MANAGER=false` until the project intentionally
migrates to Flutter's Swift Package Manager integration.

GitHub Actions reads Firebase config from these repository secrets and writes
the matching flavor file before each build:

- `FIREBASE_ANDROID_PRODUCTION_GOOGLE_SERVICES_JSON`
- `FIREBASE_ANDROID_PRIVATE_GOOGLE_SERVICES_JSON`
- `FIREBASE_IOS_PRODUCTION_GOOGLE_SERVICE_INFO_PLIST`
- `FIREBASE_IOS_PRIVATE_GOOGLE_SERVICE_INFO_PLIST`

When the relevant secret is present, the build passes
`--dart-define=FLUTTY_FIREBASE_ENABLED=true`; otherwise Firebase remains
disabled for that build.

## First-Time Setup Checklist

- [ ] Apple Developer account active
- [ ] Two apps created in App Store Connect
- [ ] Two apps created in Google Play Console
- [ ] Private Git repo created for fastlane match
- [ ] `fastlane match init` run locally
- [ ] Certificates generated for both bundle IDs
- [ ] Android upload keystore generated
- [ ] Google Play service account created with JSON key
- [ ] App Store Connect API key created with .p8 file
- [ ] All GitHub Secrets configured
- [ ] First manual upload to Play Store done (required before API uploads work)
