#!/usr/bin/env bash
# Package the native launcher shell for signing by the user's IPA installer.
# This is intentionally not an xcodebuild exportArchive or a signed distribution.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: bash package-unsigned.sh <iphoneos.app> <output.ipa>" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This packager requires macOS and the Xcode command-line tools." >&2
  exit 1
fi
APP="$1"
OUTPUT="$2"
if [[ ! -d "$APP" || "$APP" != *.app || "$OUTPUT" != *.ipa ]]; then
  echo "Expected a device .app directory and an output .ipa path." >&2
  exit 1
fi
PLIST="$APP/Info.plist"
PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$PLIST")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
if [[ "$PLATFORM" != iPhoneOS || "$EXECUTABLE" == */* || "$EXECUTABLE" == .* || -z "$EXECUTABLE" ]]; then
  echo "Refusing a simulator or invalid application bundle." >&2
  exit 1
fi
ARCHS="$(xcrun lipo -archs "$APP/$EXECUTABLE")"
if [[ "$ARCHS" != arm64 ]]; then
  echo "Expected an ARM64 device executable; got: $ARCHS" >&2
  exit 1
fi
# ARM64 alone does not distinguish an Apple Silicon simulator from a device.
BUILD_INFO="$(xcrun vtool -show-build "$APP/$EXECUTABLE")"
if ! /usr/bin/grep -Eq 'platform[[:space:]]+IOS$' <<< "$BUILD_INFO"; then
  echo "Mach-O build platform is not iOS device." >&2
  exit 1
fi
PACKAGE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sts2-ipa.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
mkdir -p "$PACKAGE_STAGE/Payload"
/usr/bin/ditto "$APP" "$PACKAGE_STAGE/Payload/$(basename "$APP")"
/usr/bin/ditto -c -k --keepParent "$PACKAGE_STAGE/Payload" "$PACKAGE_STAGE/preview.ipa"
/usr/bin/unzip -tq "$PACKAGE_STAGE/preview.ipa"
mkdir -p "$(dirname "$OUTPUT")"
mv "$PACKAGE_STAGE/preview.ipa" "$OUTPUT"
echo "Unsigned launcher preview IPA: $OUTPUT"
echo "Requires a compatible signing/install tool. Does not include a playable game runtime."
