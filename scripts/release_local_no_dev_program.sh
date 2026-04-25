#!/usr/bin/env zsh
set -euo pipefail

PROJECT="IntroStamp.xcodeproj"
SCHEME="IntroStamp"
ARCHIVE_BASE="${1:-build}"
OUT_DIR="${2:-build/local-release}"
APP_NAME="IntroStamp.app"

ARM_ARCHIVE_PATH="$ARCHIVE_BASE/IntroStamp-arm64.xcarchive"
X86_ARCHIVE_PATH="$ARCHIVE_BASE/IntroStamp-x86_64.xcarchive"

ARM_APP_DIR="$OUT_DIR/IntroStamp-arm64.app"
X86_APP_DIR="$OUT_DIR/IntroStamp-x86_64.app"
UNIVERSAL_APP_DIR="$OUT_DIR/IntroStamp-universal.app"

ARM_ZIP_NAME="IntroStamp-local-arm64.zip"
X86_ZIP_NAME="IntroStamp-local-x86_64.zip"
UNIVERSAL_ZIP_NAME="IntroStamp-local-universal.zip"

build_archive() {
  local archive_path="$1"
  local archs="$2"

  xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    archive \
    -archivePath "$archive_path" \
    ARCHS="$archs"
}

copy_archive_app() {
  local archive_path="$1"
  local out_app_dir="$2"

  local app_path="$archive_path/Products/Applications/$APP_NAME"
  if [[ ! -d "$app_path" ]]; then
    echo "Archive succeeded but app was not found at: $app_path"
    exit 1
  fi

  rm -rf "$out_app_dir"
  cp -R "$app_path" "$out_app_dir"
}

sign_app() {
  local app_dir="$1"
  codesign --force --deep --sign - --timestamp=none "$app_dir"
}

package_app() {
  local app_dir="$1"
  local zip_name="$2"

  rm -f "$OUT_DIR/$zip_name"
  ditto -c -k --keepParent "$app_dir" "$OUT_DIR/$zip_name"
  shasum -a 256 "$OUT_DIR/$zip_name" > "$OUT_DIR/$zip_name.sha256"
}

merge_universal_app() {
  local arm_app_dir="$1"
  local x86_app_dir="$2"
  local universal_app_dir="$3"

  rm -rf "$universal_app_dir"
  cp -R "$arm_app_dir" "$universal_app_dir"

  while IFS= read -r -d '' arm_file; do
    local rel_path="${arm_file#$arm_app_dir/}"
    local x86_file="$x86_app_dir/$rel_path"
    local universal_file="$universal_app_dir/$rel_path"

    if [[ ! -f "$x86_file" ]]; then
      continue
    fi

    if file -b "$arm_file" | grep -q "Mach-O" && file -b "$x86_file" | grep -q "Mach-O"; then
      lipo -create -output "$universal_file" "$arm_file" "$x86_file"
    fi
  done < <(find "$arm_app_dir" -type f -print0)
}

mkdir -p "$OUT_DIR"
mkdir -p "$ARCHIVE_BASE"

echo "[1/9] Building arm64 archive..."
build_archive "$ARM_ARCHIVE_PATH" "arm64"

echo "[2/9] Building x86_64 archive..."
build_archive "$X86_ARCHIVE_PATH" "x86_64"

echo "[3/9] Copying arm64 app bundle..."
copy_archive_app "$ARM_ARCHIVE_PATH" "$ARM_APP_DIR"

echo "[4/9] Copying x86_64 app bundle..."
copy_archive_app "$X86_ARCHIVE_PATH" "$X86_APP_DIR"

echo "[5/9] Creating universal app bundle..."
merge_universal_app "$ARM_APP_DIR" "$X86_APP_DIR" "$UNIVERSAL_APP_DIR"

echo "[6/9] Applying ad-hoc signatures..."
sign_app "$ARM_APP_DIR"
sign_app "$X86_APP_DIR"
sign_app "$UNIVERSAL_APP_DIR"

echo "[7/9] Creating zip artifacts..."
package_app "$ARM_APP_DIR" "$ARM_ZIP_NAME"
package_app "$X86_APP_DIR" "$X86_ZIP_NAME"
package_app "$UNIVERSAL_APP_DIR" "$UNIVERSAL_ZIP_NAME"

echo "[8/9] Verifying architectures..."
lipo -archs "$ARM_APP_DIR/Contents/MacOS/IntroStamp"
lipo -archs "$X86_APP_DIR/Contents/MacOS/IntroStamp"
lipo -archs "$UNIVERSAL_APP_DIR/Contents/MacOS/IntroStamp"

echo "[9/9] Done."

echo
echo "Done. Local release artifacts:"
echo "- $ARM_APP_DIR"
echo "- $OUT_DIR/$ARM_ZIP_NAME"
echo "- $OUT_DIR/$ARM_ZIP_NAME.sha256"
echo
echo "- $X86_APP_DIR"
echo "- $OUT_DIR/$X86_ZIP_NAME"
echo "- $OUT_DIR/$X86_ZIP_NAME.sha256"
echo
echo "- $UNIVERSAL_APP_DIR"
echo "- $OUT_DIR/$UNIVERSAL_ZIP_NAME"
echo "- $OUT_DIR/$UNIVERSAL_ZIP_NAME.sha256"
echo
echo "Important: This build is ad-hoc signed only (no Developer ID, no notarization)."
echo "Users may see Gatekeeper warnings when launching downloaded binaries."
