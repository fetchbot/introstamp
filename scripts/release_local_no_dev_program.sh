#!/usr/bin/env zsh
set -euo pipefail

PROJECT="IntroStamp.xcodeproj"
SCHEME="IntroStamp"
ARCHIVE_PATH="${1:-build/IntroStamp.xcarchive}"
OUT_DIR="${2:-build/local-release}"
APP_NAME="IntroStamp.app"
ZIP_NAME="IntroStamp-unnotarized.zip"

mkdir -p "$OUT_DIR"

echo "[1/5] Creating release archive (no Apple Developer Program required)..."
xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  archive \
  -archivePath "$ARCHIVE_PATH"

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive succeeded but app was not found at: $APP_PATH"
  exit 1
fi

echo "[2/5] Copying app bundle to output folder..."
rm -rf "$OUT_DIR/$APP_NAME"
cp -R "$APP_PATH" "$OUT_DIR/$APP_NAME"

echo "[3/5] Applying ad-hoc signature..."
codesign --force --deep --sign - --timestamp=none "$OUT_DIR/$APP_NAME"

echo "[4/5] Creating zip artifact..."
rm -f "$OUT_DIR/$ZIP_NAME"
ditto -c -k --keepParent "$OUT_DIR/$APP_NAME" "$OUT_DIR/$ZIP_NAME"

echo "[5/5] Writing checksum..."
shasum -a 256 "$OUT_DIR/$ZIP_NAME" > "$OUT_DIR/$ZIP_NAME.sha256"

echo
echo "Done. Local release artifacts:"
echo "- $OUT_DIR/$APP_NAME"
echo "- $OUT_DIR/$ZIP_NAME"
echo "- $OUT_DIR/$ZIP_NAME.sha256"
echo
echo "Important: This build is ad-hoc signed only (no Developer ID, no notarization)."
echo "Users may see Gatekeeper warnings when launching downloaded binaries."
