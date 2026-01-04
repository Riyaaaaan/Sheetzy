#!/bin/bash

# QDrobe Release Build Script
# This script automates the release build process for Android App Bundle

set -e  # Exit immediately if a command exits with a non-zero status

# Get current version from pubspec.yaml
CURRENT_VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //')
VERSION_NAME=$(echo $CURRENT_VERSION | cut -d'+' -f1)
BUILD_NUMBER=$(echo $CURRENT_VERSION | cut -d'+' -f2)

echo "📋 Current version: $VERSION_NAME+$BUILD_NUMBER"

# Increment build number
NEW_BUILD_NUMBER=$((BUILD_NUMBER + 1))
echo "🔢 New build number: $NEW_BUILD_NUMBER"

# Ask if user wants to bump version
echo ""
echo "Do you want to bump the version number? (current: $VERSION_NAME)"
echo "  [1] Patch (x.x.X) - bug fixes"
echo "  [2] Minor (x.X.0) - new features"
echo "  [3] Major (X.0.0) - breaking changes"
echo "  [Enter] Keep existing ($VERSION_NAME)"
read -p "Choice: " VERSION_CHOICE

case $VERSION_CHOICE in
  1)
    # Bump patch version
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION_NAME"
    NEW_PATCH=$((PATCH + 1))
    NEW_VERSION_NAME="$MAJOR.$MINOR.$NEW_PATCH"
    echo "📈 Bumping patch version to: $NEW_VERSION_NAME"
    ;;
  2)
    # Bump minor version
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION_NAME"
    NEW_MINOR=$((MINOR + 1))
    NEW_VERSION_NAME="$MAJOR.$NEW_MINOR.0"
    echo "📈 Bumping minor version to: $NEW_VERSION_NAME"
    ;;
  3)
    # Bump major version
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION_NAME"
    NEW_MAJOR=$((MAJOR + 1))
    NEW_VERSION_NAME="$NEW_MAJOR.0.0"
    echo "📈 Bumping major version to: $NEW_VERSION_NAME"
    ;;
  *)
    # Keep existing version
    NEW_VERSION_NAME=$VERSION_NAME
    echo "✓ Keeping version: $NEW_VERSION_NAME"
    ;;
esac

NEW_VERSION="$NEW_VERSION_NAME+$NEW_BUILD_NUMBER"
echo "🏷️  New full version: $NEW_VERSION"

# Update pubspec.yaml with new version
sed -i '' "s/^version: .*/version: $NEW_VERSION/" pubspec.yaml
echo "✅ Updated pubspec.yaml"

echo ""
echo "🧹 Cleaning project..."
flutter clean

echo "📦 Getting dependencies..."
flutter pub get

echo "🔨 Building release App Bundle with obfuscation..."
flutter build appbundle \
  --release \
  --obfuscate \
  --split-debug-info=build/debug-info

echo "✅ Build completed successfully!"
echo "📍 App Bundle location: build/app/outputs/bundle/release/app-release.aab"
echo "📍 Debug symbols location: build/debug-info/"
