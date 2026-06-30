# Contributing to MonkeySSH

Thank you for your interest in contributing to MonkeySSH! This document provides guidelines and instructions for contributing.

## ⚠️ Experimental Project Notice

This is an experimental project. Contributions are welcome, but please understand that:
- The architecture may change significantly
- Features may be added, removed, or redesigned
- This is not intended for production use

## Code of Conduct

Be respectful and constructive in all interactions.

## Getting Started

### Prerequisites

- Flutter 3.x or later
- Git
- Your preferred IDE (VS Code, Android Studio, IntelliJ)

### Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/monkeyssh.git
   cd monkeyssh
   ```
3. Add upstream remote:
   ```bash
   git remote add upstream https://github.com/depoll/monkeyssh.git
   ```
4. Install dependencies:
   ```bash
   flutter pub get
   ```
5. Run the app:
   ```bash
   flutter run
   ```

## Development Workflow

### Branching

- `main` - Stable release branch
- `develop` - Development branch (PR target)
- `feature/*` - Feature branches
- `fix/*` - Bug fix branches

### Making Changes

1. Create a new branch from `develop`:
   ```bash
   git checkout develop
   git pull upstream develop
   git checkout -b feature/your-feature-name
   ```

2. Make your changes following our coding standards

3. Write tests for new functionality

4. Ensure local checks cover your change:
   ```bash
   # Format code
   dart format .

   # Analyze code
   flutter analyze

   # Run tests relevant to the changed behavior
   flutter test test/path/to/relevant_test.dart
   ```

   Run the full `flutter test` suite locally for broad or high-risk changes.
   CI runs the full suite for every pull request.

5. Commit your changes:
   ```bash
   git add .
   git commit -m "feat: add your feature description"
   ```

6. Push and create a Pull Request:
   ```bash
   git push origin feature/your-feature-name
   ```

### Store Screenshots and Demo Videos

Store screenshots are generated locally because the capture flow needs real
simulators/emulators plus authenticated `copilot` and `claude` CLIs. To generate
fresh screenshots, commit only the PNG assets, and open a PR:

```bash
./scripts/create_store_screenshots_pr.sh both
```

You can pass `ios` or `android` instead of `both` for a narrower update. After
the screenshot PR merges to `main`, the Sync Store Metadata workflow validates
and uploads the committed screenshots.

Short product demo videos use the same real app, SSH, and MonkeyMux capture
flow, then compose that single live recording into several store-compliant
deliverables per platform. Generate local iOS and Android recordings with:

```bash
python3 scripts/generate_store_demo_videos.py both
python3 scripts/validate_store_demo_videos.py all
```

Each device is recorded once and composed into:

- **App Store app previews** (full-screen native app at the exact device slot
  resolution with fading caption overlays and a silent audio track):
  `ios/fastlane/app-previews/en-US/iphone_67_1.mov` (886x1920) and
  `ipad_13_1.mov` (1200x1600). App Store Connect validates resolution at upload,
  so these are native captures, not the branded canvas.
- **Google Play preview** (16:9 landscape branded promo, uploaded to YouTube and
  referenced by URL in Play Console):
  `store/demo-videos/google-play/monkeyssh-google-play-promo.mp4` (1920x1080).
- **Ads/marketing** (portrait branded canvas):
  `store/demo-videos/ads/monkeyssh-ios-ads.mp4` and `monkeyssh-android-ads.mp4`.

The validator checks per-slot resolution, 15-30s duration, H.264, an audio track
on the Apple previews, and that the live app region actually advances through
scenes.

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `style:` - Formatting, no code change
- `refactor:` - Code restructuring
- `test:` - Adding/updating tests
- `chore:` - Maintenance tasks

Examples:
```
feat: add SSH key generation
fix: resolve connection timeout on slow networks
docs: update README with build instructions
test: add unit tests for host repository
```

## Coding Standards

### Dart/Flutter

- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart)
- Use `dart format` for consistent formatting
- Prefer `const` constructors where possible
- Use meaningful variable and function names
- Document public APIs with dartdoc comments

### Architecture

- Follow the established project structure
- Keep widgets small and focused
- Use Riverpod for state management
- Place business logic in services/repositories

### Testing

- Write unit tests for business logic
- Write widget tests for UI components
- Test edge cases and error conditions

## Pull Request Process

1. Ensure your PR targets the `develop` branch
2. Fill out the PR template completely
3. Link any related issues
4. Ensure CI checks pass
5. Request review from maintainers
6. Address review feedback promptly

### PR Checklist

- [ ] Code follows project style guidelines
- [ ] Tests added/updated for changes
- [ ] Documentation updated if needed
- [ ] No breaking changes (or clearly documented)
- [ ] CI checks pass

## Reporting Issues

### Bug Reports

Include:
- Flutter version (`flutter --version`)
- Platform (iOS, Android, macOS, Windows, Linux)
- Steps to reproduce
- Expected vs actual behavior
- Screenshots/logs if applicable

### Feature Requests

Include:
- Clear description of the feature
- Use case / motivation
- Proposed implementation (optional)

## Releases & Deployment

- **PR Preview Builds**: Every PR automatically builds a `private` preview and posts a downloadable APK. Comment `/deploy` on the PR to queue the current preview SHA for TestFlight + Play internal deployment, or run `Deploy PR Preview` manually from the Actions tab. The deploy workflow reuses preview artifacts when their build number is still newer than the last deployed private build; otherwise it rebuilds with a fresh build number first.
- **Production Releases**: Create a GitHub Release with a `vX.Y.Z` tag, or use the manual workflow dispatch. This deploys the `production` flavor to the App Store and Play Store.
- **Flavors**: The app has two build flavors — `private` (for testing) and `production` (for store releases). See [docs/deployment.md](docs/deployment.md).

### Building flavors locally

For iOS release validation, use the Xcode bundle that matches the installed runtime:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The current supported release selector is `/Applications/Xcode.app` (Xcode 26.2 on the macOS 26 image). Do not validate with side-by-side Xcode versions unless their iOS runtime is installed.

```bash
flutter build apk --flavor private --release
flutter build apk --flavor production --release
flutter build ios --flavor private --release --no-codesign
flutter build ios --flavor production --release --no-codesign
```

## Questions?

Open a GitHub Discussion for questions or ideas.

Thank you for contributing! 🎉
