# Copilot Instructions for Flutty

## Build, Test, and Lint

```bash
# Install dependencies
flutter pub get

# Run code generator (Drift, Freezed, Riverpod)
dart run build_runner build --delete-conflicting-outputs

# Analyze code (treats warnings as errors in CI)
flutter analyze --fatal-warnings

# Format code
dart format .

# Run all tests
flutter test

# Run a single test file
flutter test test/unit/database_test.dart

# Run tests matching a name pattern
flutter test --name "insert and retrieve host"

# Run tests with coverage
flutter test --coverage

# Integration tests
flutter test integration_test
```

## Architecture

This is a cross-platform SSH client using **Clean Architecture** with three layers:

### Data Layer (`lib/data/`)
- **database/**: Drift (SQLite) schemas and generated code. Tables are defined as classes extending `Table`. Run `build_runner` after modifying.
- **repositories/**: Database access patterns. Each repository wraps database operations and exposes a Riverpod provider.

### Domain Layer (`lib/domain/`)
- **models/**: Domain entities (terminal themes, etc.)
- **services/**: Business logic services (SSH, auth, key management). Services receive repositories via constructor injection.

### Presentation Layer (`lib/presentation/`)
- **screens/**: Full page widgets, one per feature
- **widgets/**: Reusable UI components

### App Layer (`lib/app/`)
- **router.dart**: GoRouter configuration with auth-based redirects
- **theme.dart**: Material theme configuration

### State Management
Uses **Riverpod** throughout:
- Providers defined at the bottom of service/repository files
- `StateNotifier` for mutable state (e.g., `ActiveSessionsNotifier`)
- Async data uses `AsyncValue` pattern

### Navigation
Uses **GoRouter** with named routes. Route names are constants in the `Routes` class.

## Code Conventions

### Generated Files
Files matching `*.g.dart`, `*.freezed.dart`, `*.mocks.dart` are generated. Never edit manually. Regenerate with:
```bash
dart run build_runner build --delete-conflicting-outputs
```

### Linting
Strict linting is enforced (see `analysis_options.yaml`):
- `prefer_single_quotes` - use single quotes for strings
- `require_trailing_commas` - add trailing commas
- `prefer_const_constructors` - use const where possible
- `public_member_api_docs` - document all public APIs with dartdoc

### Database Testing
Use in-memory database for tests:
```dart
db = AppDatabase.forTesting(NativeDatabase.memory());
```

### Commit Messages
Follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`

### Branching
- `main` - stable releases
- `develop` - PR target for new work
- `feature/*`, `fix/*` - working branches
