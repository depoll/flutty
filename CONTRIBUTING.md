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

4. Ensure all checks pass:
   ```bash
   # Format code
   dart format .
   
   # Analyze code
   flutter analyze
   
   # Run tests
   flutter test
   ```

5. Commit your changes:
   ```bash
   git add .
   git commit -m "feat: add your feature description"
   ```

6. Push and create a Pull Request:
   ```bash
   git push origin feature/your-feature-name
   ```

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
- Aim for 80%+ code coverage
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

## Questions?

Open a GitHub Discussion for questions or ideas.

Thank you for contributing! 🎉
