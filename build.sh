#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (($# > 1)); then
  echo "Usage: ./build.sh [decrypted-tver.ipa]" >&2
  exit 2
fi

mkdir -p "$SCRIPT_DIR/packages"
INPUT_IPA="${1:-$SCRIPT_DIR/packages/jp.hamitv.hamitvapp1.ipa}"
OUTPUT_IPA="$SCRIPT_DIR/packages/TVerPiP.ipa"

if [[ ! -f "$INPUT_IPA" ]]; then
  echo "decrypted TVer ipa not found: $INPUT_IPA" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/tverpip-mod.XXXXXX)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

cleanup() {
  if [[ -d "$WORK_DIR" && "$WORK_DIR" == /tmp/tverpip-mod.* ]]; then
    find "$WORK_DIR" -depth -delete
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK_DIR/app"
unzip -q "$INPUT_IPA" -d "$WORK_DIR/app"

shopt -s nullglob
APP_PATHS=("$WORK_DIR"/app/Payload/*.app)
shopt -u nullglob
if ((${#APP_PATHS[@]} != 1)); then
  echo "expected exactly one app in Payload, found ${#APP_PATHS[@]}" >&2
  exit 1
fi

APP_PATH="${APP_PATHS[0]}"
INFO_PLIST="$APP_PATH/Info.plist"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
MAIN_EXECUTABLE="$APP_PATH/$EXECUTABLE_NAME"
INJECTED_DYLIB="$APP_PATH/Frameworks/TVerPiP.dylib"

swift "$SCRIPT_DIR/tools/TVerPiPPatcher.swift" patch-info "$INFO_PLIST"

mkdir -p "$APP_PATH/Frameworks"
xcrun clang -arch arm64 -isysroot "$SDK_PATH" -miphoneos-version-min=15.0 \
  -fobjc-arc -fblocks -DTVERPIP_DIAGNOSTIC="${TVERPIP_DIAGNOSTIC:-0}" \
  -dynamiclib "$SCRIPT_DIR/Sources/TVerPiP.m" \
  -framework Foundation -framework AVFoundation -framework AVKit \
  -framework MediaPlayer -framework UIKit -framework CoreMedia -framework CoreGraphics \
  -install_name '@executable_path/Frameworks/TVerPiP.dylib' \
  -o "$INJECTED_DYLIB"

swift "$SCRIPT_DIR/tools/TVerPiPPatcher.swift" add-load-dylib "$MAIN_EXECUTABLE" \
  '@executable_path/Frameworks/TVerPiP.dylib'
codesign --force --sign - "$INJECTED_DYLIB"

if [[ -e "$OUTPUT_IPA" ]]; then
  find "$OUTPUT_IPA" -maxdepth 0 -type f -delete
fi
(cd "$WORK_DIR/app" && zip -qry "$OUTPUT_IPA" Payload)
echo "Built: $OUTPUT_IPA"
