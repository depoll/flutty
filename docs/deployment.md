# Deployment Guide

This guide covers setting up automated deployment to TestFlight, Play Store internal testing, and production store releases.

## App Variants

| Variant | Android Package | iOS Bundle ID | Display Name | Purpose |
|---------|----------------|---------------|--------------|---------|
| **private** | `xyz.depollsoft.monkeyssh.private` | `xyz.depollsoft.monkeyssh.private` | MonkeySSH Private | PR previews, internal testing |
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
3. Generate certificates for both bundle IDs:
   ```bash
   bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh
   bundle exec fastlane match appstore --app_identifier xyz.depollsoft.monkeyssh.private
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

For local development, create `android/app/key.properties` (see `key.properties.example`).

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

Triggered automatically on PRs to `main` or `develop`. Builds the **private** flavor and deploys to:
- **iOS**: TestFlight (MonkeySSH Private)
- **Android**: Play Store internal testing track

Version format: `X.Y.Z-pr.N` with epoch-minute build numbers

### Release (`release.yml`)

Triggered by:
- Creating a GitHub Release (tag format: `vX.Y.Z`)
- Manual workflow dispatch with version input

Builds the **production** flavor and deploys to:
- **iOS**: App Store (submitted, not auto-released)
- **Android**: Play Store production track

Metadata (description, icons, etc.) is synced automatically on release deploys.

### Sync Metadata (`sync-metadata.yml`)

Manually triggered workflow to sync store metadata without a new build. Useful for updating app descriptions, icons, or other listing details.

Supports selecting:
- **Platform**: iOS, Android, or both
- **App**: private, production, or both

### Build Numbers

All builds use epoch-minute build numbers (`$(date +%s) / 60`) — monotonically increasing regardless of how many PRs are active. PR info is encoded in the version name (`X.Y.Z-pr.N`), not the build number.

## Store Metadata

Store metadata (descriptions, icons, etc.) is managed per-app in the repository. Each app variant (private and production) has its own metadata directory with distinct names and icons.

### iOS (App Store Connect)

```
ios/fastlane/
├── metadata-private/        # MonkeySSH β (preview app)
│   ├── en-US/
│   │   ├── name.txt         # "MonkeySSH β"
│   │   ├── subtitle.txt
│   │   ├── description.txt
│   │   ├── keywords.txt
│   │   ├── release_notes.txt
│   │   ├── privacy_url.txt
│   │   └── support_url.txt
│   ├── copyright.txt
│   ├── primary_category.txt
│   └── app_icon.png         # 1024x1024 (private banner icon)
└── metadata-production/     # MonkeySSH (production app)
    ├── en-US/
    │   └── (same structure)
    ├── copyright.txt
    ├── primary_category.txt
    └── app_icon.png         # 1024x1024 (production icon)
```

### Android (Google Play)

```
android/fastlane/
├── metadata-private/        # MonkeySSH β (preview app)
│   └── android/en-US/
│       ├── title.txt        # "MonkeySSH β"
│       ├── short_description.txt
│       ├── full_description.txt
│       ├── icon.png         # 512x512 (private banner icon)
│       └── changelogs/
│           └── default.txt
└── metadata-production/     # MonkeySSH (production app)
    └── android/en-US/
        └── (same structure)
```

Edit these files and metadata will sync on the next release deploy, or trigger the **Sync Metadata** workflow manually.

> **Note:** Apple and Google require unique app names per account. The private app uses "MonkeySSH β" to distinguish it from the production "MonkeySSH" listing.

## Building Flavors Locally

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
