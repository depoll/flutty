#!/bin/bash
# Setup script for Flutty development environment

set -e

echo "Setting up Flutty development environment..."

# Install git hooks
echo "Installing git hooks..."
cp scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

# Get dependencies
echo "Installing dependencies..."
flutter pub get

# Run code generation (when we add it)
# echo "Running code generation..."
# dart run build_runner build --delete-conflicting-outputs

echo "Setup complete! You can now run 'flutter run' to start the app."
