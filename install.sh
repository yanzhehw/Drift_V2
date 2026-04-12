#!/bin/bash
#
# Drift_V2 Screensaver Installer for macOS
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/yanzhehw/drift-screensaver/main/install.sh | bash
#
# Or from a cloned repo:
#   ./install.sh
#
set -euo pipefail

# --- Colors ---
if [ -t 1 ]; then
    BOLD="\033[1m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    RED="\033[31m"
    RESET="\033[0m"
else
    BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi

step()  { printf "${BOLD}${GREEN}==>${RESET}${BOLD} %s${RESET}\n" "$1"; }
warn()  { printf "${BOLD}${YELLOW}==> WARNING:${RESET} %s\n" "$1"; }
fail()  { printf "${BOLD}${RED}==> ERROR:${RESET} %s\n" "$1" >&2; exit 1; }

# --- State ---
RUST_WE_INSTALLED=false
CLONED_TMPDIR=""

cleanup() {
    if [ -n "$CLONED_TMPDIR" ] && [ -d "$CLONED_TMPDIR" ]; then
        rm -rf "$CLONED_TMPDIR"
    fi
}
trap cleanup EXIT

# --- Pre-flight ---
step "Checking prerequisites..."

[ "$(uname)" = "Darwin" ] || fail "This installer only works on macOS."

if ! command -v clang >/dev/null 2>&1; then
    fail "Xcode Command Line Tools not found. Install them with: xcode-select --install"
fi

# --- Locate repo ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

if [ -f "$SCRIPT_DIR/Cargo.toml" ] && [ -d "$SCRIPT_DIR/drift" ]; then
    ROOT_DIR="$SCRIPT_DIR"
else
    # Running via curl | bash — clone to a temp directory
    step "Cloning repository..."
    CLONED_TMPDIR="$(mktemp -d)"
    git clone --depth 1 https://github.com/yanzhehw/drift-screensaver.git "$CLONED_TMPDIR" 2>&1 | tail -1
    ROOT_DIR="$CLONED_TMPDIR"
fi

# --- Rust ---
if command -v cargo >/dev/null 2>&1; then
    step "Rust toolchain detected ($(rustc --version 2>/dev/null || echo 'unknown'))"
else
    step "Installing Rust toolchain (will be removed after build)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path >/dev/null 2>&1
    RUST_WE_INSTALLED=true
fi

# Source cargo env (needed whether pre-installed or just installed)
if [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi

command -v cargo >/dev/null 2>&1 || fail "cargo not found after install. Check your PATH."

# --- Build ---
step "Building Drift_V2 screensaver (this may take a few minutes)..."
cargo build -p drift-v2-screensaver --release --manifest-path="$ROOT_DIR/Cargo.toml" 2>&1 | grep -E "Compiling drift|Compiling flux|Finished" || true

STATIC_LIB="$ROOT_DIR/target/release/libdrift_v2_screensaver.a"
[ -f "$STATIC_LIB" ] || fail "Build failed: static library not found."

# --- Assemble bundle ---
step "Assembling Drift_V2.saver bundle..."
SAVER_DIR="$ROOT_DIR/drift"
BUILD_DIR="$ROOT_DIR/target/saver-build"
BUNDLE_DIR="$BUILD_DIR/Drift_V2.saver"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"
cp "$SAVER_DIR/Info.plist" "$BUNDLE_DIR/Contents/"

clang -bundle \
    -fobjc-arc \
    -o "$MACOS_DIR/Drift_V2" \
    -I "$SAVER_DIR/include" \
    "$SAVER_DIR/objc/DriftV2ScreenSaverView.m" \
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

# --- Sign ---
step "Code signing (ad-hoc)..."
codesign --force --deep --sign - "$BUNDLE_DIR" 2>/dev/null

# --- Install ---
step "Installing to ~/Library/Screen Savers/..."
DEST="$HOME/Library/Screen Savers/Drift_V2.saver"

# Kill stale screensaver agents so they reload
killall legacyScreenSaver 2>/dev/null || true
killall WallpaperAgent 2>/dev/null || true

mkdir -p "$HOME/Library/Screen Savers"
rm -rf "$DEST"
cp -R "$BUNDLE_DIR" "$DEST"

# --- Cleanup ---
step "Cleaning up build artifacts..."
cargo clean --manifest-path="$ROOT_DIR/Cargo.toml" 2>/dev/null || true

if [ "$RUST_WE_INSTALLED" = true ]; then
    step "Removing Rust toolchain (was not installed before)..."
    rustup self uninstall -y 2>/dev/null || true
fi

# CLONED_TMPDIR cleanup handled by trap

# --- Done ---
BUNDLE_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1 | xargs)
printf "\n"
printf "${BOLD}${GREEN}Drift_V2 screensaver installed successfully!${RESET}\n"
printf "\n"
printf "  Installed to: %s (%s)\n" "$DEST" "$BUNDLE_SIZE"
printf "\n"
printf "  ${BOLD}Next steps:${RESET}\n"
printf "    1. Restart ${BOLD}System Settings > Screen Saver${RESET}\n"
printf "    2. Go to \"Others\" and select ${BOLD}Drift_V2${RESET}\n"
printf "    3. Click ${BOLD}Options${RESET} to choose a color scheme\n"
printf "\n"
printf "  To uninstall:\n"
printf "    rm -rf ~/Library/Screen\\ Savers/Drift_V2.saver\n"
printf "\n"
