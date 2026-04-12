#!/bin/bash
#
# Build the Drift_V2.saver macOS screen saver bundle.
#
# Usage:
#   ./build.sh          # build only
#   ./build.sh install  # build + install to ~/Library/Screen Savers/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi

echo "==> Building Rust static library (release)..."
cargo build -p drift-v2-screensaver --release --manifest-path="$ROOT_DIR/Cargo.toml"

STATIC_LIB="$ROOT_DIR/target/release/libdrift_v2_screensaver.a"
if [ ! -f "$STATIC_LIB" ]; then
    echo "ERROR: static library not found at $STATIC_LIB"
    exit 1
fi

BUILD_DIR="$ROOT_DIR/target/saver-build"
BUNDLE_DIR="$BUILD_DIR/Drift_V2.saver"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"

echo "==> Assembling bundle layout..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"

cp "$SCRIPT_DIR/Info.plist" "$BUNDLE_DIR/Contents/"

echo "==> Compiling Objective-C and linking bundle..."
clang -bundle \
    -fobjc-arc \
    -o "$MACOS_DIR/Drift_V2" \
    -I "$SCRIPT_DIR/include" \
    "$SCRIPT_DIR/objc/DriftV2ScreenSaverView.m" \
    "$STATIC_LIB" \
    -framework ScreenSaver \
    -framework AppKit \
    -framework Foundation \
    -framework Metal \
    -framework QuartzCore \
    -framework CoreGraphics \
    -framework IOKit \
    -framework IOSurface \
    -lc++ \
    -dead_strip

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "==> Bundle built: $BUNDLE_DIR"
ls -lh "$MACOS_DIR/Drift_V2"

if [ "${1:-}" = "install" ]; then
    DEST="$HOME/Library/Screen Savers/Drift_V2.saver"
    echo "==> Installing to $DEST"

    killall "System Preferences" 2>/dev/null || true
    killall "legacyScreenSaver" 2>/dev/null || true
    killall "WallpaperAgent" 2>/dev/null || true

    rm -rf "$DEST"
    cp -R "$BUNDLE_DIR" "$DEST"
    echo "==> Installed. Open System Settings > Screen Saver to select Drift_V2."
fi

echo "==> Done."
